# Kernel updates

GitHub Releases remain kernel-only downloads. A separate signed `trixie/main` APT
repository is deployed to <https://r0bb10.github.io/Proxmox-Raspberry/> by
`.github/workflows/publish-kernel-apt.yml`. The kernel build calls it after a
successful release; it can also be run manually. All published release kernels
are retained, with flavour-specific metapackages. No automatic reboot is enabled.
The previous flat (`Suites: ./`) layout remains available for existing clients;
new installations use `Suites: trixie` and `Components: main`.

## Existing installations

Copy `configs/rpi-pve-kernel.asc` to `/etc/apt/keyrings/` and
`configs/rpi-pve-kernel.sources` to `/etc/apt/sources.list.d/` (mode 0644).
Verify the public key fingerprint through a trusted copy of this repository:

```text
8034 55B1 FFA1 CBF0 AC81 652F 5D3E 5B02 AFC1 CAE5
```

Then install the fallback helper first:

```sh
apt-get update
apt-get --no-remove install rpi-pve-kernel-support
apt-get --no-remove install rpi-pve-kernel-v8
```

Use `rpi-pve-kernel-2712` for Pi 5 once a matching kernel release is published.
Future images include the key, deb822 source, helper and matching metapackage.
Their Proxmox source is ARM64-only to avoid mixing incompatible versions of
architecture-independent packages from the AMD64 index.

## Updating and rollback

```sh
apt-get update
apt-get --no-remove dist-upgrade
```

Review package output and reboot manually when convenient. Kernel installation
prepares `/boot/firmware/rollback/` with the previous kernel, its initramfs, DTBs
and overlays. Both the new and previous kernel packages are marked manual, so
APT autoremove does not discard them. Older kernels are not automatically purged.

To select the prepared fallback, copy `/boot/firmware/config-rollback.txt` over
`/boot/firmware/config.txt`, then reboot. If the new kernel cannot boot, mount
the FAT boot partition on another machine and copy `config-rollback.txt` over
`config.txt` there. This is a **manual** recovery path, not an automatic boot
failure detector. Save your current config before selecting the fallback.
Restore the normal config to return to the current kernel. Do not delete the
fallback kernel package while its boot configuration is in use.

Older packages can also be downloaded or installed from APT; merely installing
an older kernel does not override raspi-firmware's selection of the newest one.
Choose its matching boot payload explicitly instead of assuming a package
downgrade changes the boot target.

## Publishing

Pages uses the GitHub Actions source. The repository's Actions secrets contain
`APT_SIGNING_KEY` (ASCII-armored private signing key) and
`APT_SIGNING_FINGERPRINT`. The public key is tracked under `configs/`.
Keep the private key out of source control and logs.

Metapackages are rebuilt reproducibly. The publisher rejects replaced or missing
previously published package files. Never replace an existing kernel `.deb`:
use a new package version for rebuilds. Likewise, changes to the fallback helper
require bumping its package version in `tools/publish-kernel-apt.py`. Removing
older GitHub Releases will intentionally fail publication rather than silently
drop rollback packages.
