#!/usr/bin/env bash
set -Eeuo pipefail
export GIT_TERMINAL_PROMPT=0

root=$(realpath "$(dirname "$0")/..")
work=${WORK_DIR:-"$root/work"}
pve_source="$work/pve-kernel"
pve_git_url=https://git.proxmox.com/git/pve-kernel.git
pve_head=${PVE_HEAD:?PVE_HEAD must be resolved by the workflow}
platform=${PVE_PLATFORM:-pi4}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# Select platform-specific firmware filenames and configuration inputs.
[[ $(dpkg --print-architecture) == arm64 ]] || die "native arm64 build required"

case "$platform" in
    pi4)
        boot_kernel=kernel8.img
        boot_initramfs=initramfs8
        boot_dtb=bcm2711-rpi-4-b.dtb
        raspi_config="$root/configs/raspberry-pi4.config"
        raspi_opts="$root/configs/raspberry-pi4.opts"
        ;;
    pi5)
        boot_kernel=kernel_2712.img
        boot_initramfs=initramfs_2712
        boot_dtb=bcm2712-rpi-5-b.dtb
        raspi_config="$root/configs/raspberry-pi5.config"
        raspi_opts="$root/configs/raspberry-pi5.opts"
        ;;
    *) die "PVE_PLATFORM must be pi4 or pi5" ;;
esac

# Verify the repository inputs before downloading build sources.
for file in \
    "$root/patches/boot.patch" \
    "$raspi_config" \
    "$raspi_opts" \
    "$root/configs/proxmox.opts"; do
    [[ -f $file ]] || die "missing scaffold input: $file"
done

mkdir -p "$work"
[[ $pve_head =~ ^[0-9a-f]{40}$ ]] || die "invalid PVE_HEAD"

# Fetch the exact PVE source revision resolved by the workflow.
rm -rf "$pve_source"
git clone --quiet --depth 1 --no-tags "$pve_git_url" "$pve_source"
if [[ $(git -C "$pve_source" rev-parse HEAD) != "$pve_head" ]]; then
    git -C "$pve_source" fetch --quiet --depth 1 origin "$pve_head"
    git -C "$pve_source" checkout --quiet FETCH_HEAD
fi

printf 'PVE_HEAD=%s\nPI_CONFIG=%s\n' "$pve_head" "$raspi_config"

# Adapt PVE package installation for Raspberry Pi firmware boot files.
boot_patch="$work/boot.patch"
sed \
    -e "s|@BOOT_KERNEL@|$boot_kernel|g" \
    -e "s|@BOOT_INITRAMFS@|$boot_initramfs|g" \
    -e "s|@BOOT_DTB@|$boot_dtb|g" \
    "$root/patches/boot.patch" > "$boot_patch"
git -C "$pve_source" apply --unidiff-zero --check "$boot_patch"
git -C "$pve_source" apply --unidiff-zero "$boot_patch"

# Replace PVE's generic ARM64 baseline with the checked-in Pi base config.
: > "$pve_source/debian/rules.d/config-arm64.opts"
while IFS= read -r option; do
    [[ -z $option || $option == \#* ]] && continue
    printf '%s\n' "$option" >> "$pve_source/debian/rules.d/config-arm64.opts"
done < <(cat "$raspi_opts" "$root/configs/proxmox.opts")

# Prepare the PVE package tree, resolve its configuration, and build packages.
kernel_version=$(sed -n 's/^KERNEL_MAJ=//p' "$pve_source/Makefile").$(sed -n 's/^KERNEL_MIN=//p' "$pve_source/Makefile").$(sed -n 's/^KERNEL_PATCHLEVEL=//p' "$pve_source/Makefile")
build_dir="$pve_source/proxmox-kernel-$kernel_version"

(
    cd "$pve_source"
    make build-dir-fresh
    cp "$raspi_config" "$build_dir/ubuntu-kernel/.config"
    mk-build-deps -ir --tool 'apt-get -y --no-install-recommends' "$build_dir/debian/control"
    make -C "$build_dir" -f debian/rules .config_mark
    make deb
)

printf 'Built PVE Raspberry Pi kernel packages in %s\n' "$pve_source"
