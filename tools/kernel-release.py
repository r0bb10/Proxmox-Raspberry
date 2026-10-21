#!/usr/bin/env python3
"""Plan missing kernel flavours and publish assets without replacing packages."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def release_assets(repo, tag):
    result = subprocess.run(['gh', 'api', f'repos/{repo}/releases/tags/{tag}'],
                            capture_output=True, text=True)
    if result.returncode:
        if 'HTTP 404' in result.stderr:
            return None
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)['assets']


def plan_builds(base, selection, assets, force=False):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?-rpi', base):
        raise ValueError(f'Invalid kernel base: {base}')
    if selection not in ('all', 'v8', '2712'):
        raise ValueError(f'Invalid flavour selection: {selection}')
    names = {asset['name'] for asset in assets or []}
    flavours = ['v8', '2712'] if selection == 'all' else [selection]
    return {'include': [
        {'flavour': flavour, 'kernel_version': f'{base}-{flavour}'}
        for flavour in flavours
        if force or f'linux-image-{base}-{flavour}.deb' not in names
    ]}


def publish(repo, tag, matrix, directory):
    expected = {f"linux-image-{item['kernel_version']}.deb" for item in matrix['include']}
    files = {path.name: path for path in Path(directory).glob('*.deb')}
    if files.keys() != expected:
        raise ValueError(f'Expected {sorted(expected)}, found {sorted(files)}')
    assets = release_assets(repo, tag)
    if assets is None:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', repo,
                        '--target', os.environ['GITHUB_SHA'], '--title', tag,
                        '--notes', 'Custom ARM64 Proxmox VE kernels for Raspberry Pi. '
                        'Use the v8 package for Pi 4 or the 2712 package for Pi 5.'], check=True)
        assets = []
    existing = {asset['name']: asset for asset in assets}
    for name, path in files.items():
        if name in existing:
            digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
            if existing[name].get('digest') != digest:
                raise ValueError(f'Refusing to replace published {name}; use a new package version')
            print(f'{name}: identical published asset retained')
        else:
            subprocess.run(['gh', 'release', 'upload', tag, str(path), '--repo', repo], check=True)
            print(f'{name}: added to {tag}')


def main():
    repo = os.environ['GITHUB_REPOSITORY']
    tag = os.environ['RELEASE_TAG']
    if sys.argv[1] == 'plan':
        matrix = plan_builds(tag, os.environ.get('FLAVOUR_INPUT') or 'all',
                             release_assets(repo, tag), os.environ.get('FORCE_INPUT') == 'true')
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write('matrix=' + json.dumps(matrix, separators=(',', ':')) + '\n')
            output.write('build=' + str(bool(matrix['include'])).lower() + '\n')
        print(json.dumps(matrix, indent=2))
    elif sys.argv[1] == 'publish':
        publish(repo, tag, json.loads(os.environ['BUILD_MATRIX']), 'kernel')
    else:
        raise ValueError('Expected plan or publish')


if __name__ == '__main__':
    main()
