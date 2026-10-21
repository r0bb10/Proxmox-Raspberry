#!/usr/bin/env python3
"""Build a signed trixie/main APT repository from GitHub release assets."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.error
import urllib.request


def run(*args, **kwargs):
    return subprocess.check_output(args, **kwargs).decode().strip()


root = Path(__file__).resolve().parent.parent
# Make regenerated metapackages byte-identical for an unchanged version.
os.environ['SOURCE_DATE_EPOCH'] = '0'
out = Path(os.environ.get('APT_OUTPUT', 'apt-site')).resolve()
out.mkdir(parents=True, exist_ok=True)
(out / 'pool').mkdir(exist_ok=True)
repo = os.environ['GITHUB_REPOSITORY']
url = os.environ.get('APT_URL', 'https://r0bb10.github.io/Proxmox-Raspberry/')
# Reject replaced release assets: an APT package version must be immutable.
known = {}
for index in ['dists/trixie/main/binary-arm64/Packages', 'Packages']:
    try:
        with urllib.request.urlopen(url + index, timeout=30) as response:
            for stanza in response.read().decode().split('\n\n'):
                fields = dict(line.split(': ', 1) for line in stanza.splitlines()
                              if ': ' in line and not line.startswith(' '))
                if 'Filename' in fields:
                    known[fields['Filename']] = fields['SHA256']
        break
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise

releases = [[json.loads(line) for line in run(
    'gh', 'api', f'repos/{repo}/releases?per_page=100',
    '--paginate', '--jq', '.[] | @json').splitlines()]]
count = 0
for page in releases:
    for release in page:
        if release['draft'] or release['prerelease']:
            continue
        for asset in release['assets']:
            match = re.fullmatch(r'linux-image-(.+-rpi-(v8|2712))\.deb', asset['name'])
            if not match:
                continue
            kernel, flavour = match.groups()
            dest = out / 'pool' / asset['name']
            subprocess.run(['gh', 'release', 'download', release['tag_name'],
                            '--repo', repo, '--pattern', asset['name'],
                            '--dir', str(out / 'pool'), '--clobber'], check=True)
            digest = hashlib.sha256(dest.read_bytes()).hexdigest()
            filename = 'pool/' + dest.name
            if filename in known and known[filename] != digest:
                raise SystemExit(f'Replaced immutable package: {filename}')
            package = run('dpkg-deb', '-f', str(dest), 'Package')
            version = run('dpkg-deb', '-f', str(dest), 'Version')
            arch = run('dpkg-deb', '-f', str(dest), 'Architecture')
            if package != 'linux-image-' + kernel or arch != 'arm64':
                raise SystemExit(f'Unexpected package identity: {dest}')
            stage = out / 'stage' / f'{flavour}-{version}' / 'DEBIAN'
            stage.mkdir(parents=True, exist_ok=True)
            (stage / 'control').write_text(f'''Package: rpi-pve-kernel-{flavour}
Version: {version}
Architecture: arm64
Maintainer: Proxmox Raspberry Build <root@localhost>
Section: kernel
Priority: optional
Depends: {package} (= {version}), rpi-pve-kernel-support (>= 1.0)
Description: Track the custom Raspberry Pi {flavour} Proxmox kernel
''')
            subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(stage.parent),
                            str(out / 'pool' / f'rpi-pve-kernel-{flavour}_{version}_arm64.deb')], check=True)
            count += 1
if not count:
    raise SystemExit('No release kernels found')

support = out / 'support'
(support / 'DEBIAN').mkdir(parents=True, exist_ok=True)
(support / 'DEBIAN/control').write_text('''Package: rpi-pve-kernel-support
Version: 1.0
Architecture: all
Maintainer: Proxmox Raspberry Build <root@localhost>
Section: kernel
Priority: optional
Depends: apt, coreutils, findutils
Description: Preserve an offline Raspberry Pi kernel boot fallback
''')
hook = support / 'etc/kernel/postinst.d/zz-rpi-pve-rollback'
hook.parent.mkdir(parents=True, exist_ok=True)
hook.write_bytes((root / 'tools/kernel-rollback.sh').read_bytes())
hook.chmod(0o755)
subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(support),
                str(out / 'pool/rpi-pve-kernel-support_1.0_all.deb')], check=True)
packages = run('dpkg-scanpackages', '--multiversion', 'pool', cwd=out) + '\n'
for filename, digest in known.items():
    package_file = out / filename
    if not package_file.is_file():
        raise SystemExit(f'Refusing to drop published package: {filename}')
    if hashlib.sha256(package_file.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'Replaced immutable package: {filename}; bump its version')
(out / 'Packages').write_text(packages)
with (out / 'Packages.gz').open('wb') as target:
    subprocess.run(['gzip', '-n', '-9', '-c', str(out / 'Packages')], stdout=target, check=True)
suite = out / 'dists/trixie'
index = suite / 'main/binary-arm64'
index.mkdir(parents=True, exist_ok=True)
for name in ['Packages', 'Packages.gz']:
    shutil.copyfile(out / name, index / name)
# Do not ship unpacked build trees through Pages.
shutil.rmtree(out / 'stage')
shutil.rmtree(support)
(out / 'rpi-pve-kernel.asc').write_bytes((root / 'configs/rpi-pve-kernel.asc').read_bytes())
(out / '.nojekyll').touch()
key = os.environ['APT_SIGNING_FINGERPRINT']


def sign_release(directory, options):
    args = ['apt-ftparchive', '-o', 'APT::FTPArchive::Release::Origin=Proxmox-Raspberry',
            '-o', 'APT::FTPArchive::Release::Label=Proxmox-Raspberry custom kernels']
    for name, value in options.items():
        args += ['-o', f'APT::FTPArchive::Release::{name}={value}']
    release = run(*args, 'release', '.', cwd=directory)
    (directory / 'Release').write_text(release + '\n')
    for operation, filename in [('--clearsign', 'InRelease'), ('--detach-sign', 'Release.gpg')]:
        subprocess.run(['gpg', '--batch', '--yes', '--local-user', key,
                        '--digest-algo', 'SHA256', '--armor', operation,
                        '--output', str(directory / filename), str(directory / 'Release')], check=True)


sign_release(suite, {'Suite': 'trixie', 'Codename': 'trixie',
                     'Components': 'main', 'Architectures': 'arm64'})
# Keep existing flat-source clients working during migration.
sign_release(out, {'Architectures': 'arm64 all'})
print(f'Published metadata for {count} kernels; release assets untouched.')
