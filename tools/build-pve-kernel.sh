#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

root=$(realpath "$(dirname "$0")/..")
work=${WORK_DIR:-"$root/work"}
source="$work/rpi-linux"
build="$work/rpi-linux-build"
zfs="$work/zfs-${ZFS_VERSION:-2.4.4}"
output=${ARTIFACT_DIR:-"$root/.artifacts/packages"}
rpi_head=${RPI_HEAD:?RPI_HEAD must be resolved by the workflow}
rpi_git_url=${RPI_GIT_URL:-https://github.com/raspberrypi/linux.git}
rpi_flavour=${RPI_FLAVOUR:-v8}
zfs_version=${ZFS_VERSION:-2.4.4}
zfs_ref=${ZFS_REF:-zfs-$zfs_version}
jobs=${JOBS:-$(nproc)}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[[ $(dpkg --print-architecture) == arm64 ]] || die "native arm64 build required"
[[ $rpi_head =~ ^[0-9a-f]{40}$ ]] || die "invalid RPI_HEAD"
[[ $rpi_flavour == v8 ]] || die "Pi 4 builds require RPI_FLAVOUR=v8"
[[ -f $root/configs/proxmox.opts ]] || die "missing configs/proxmox.opts"
[[ -f $root/patches/kernel.patch ]] || die "missing PMX metadata patch"

rm -rf "$source" "$build" "$zfs"
mkdir -p "$work" "$output"

git init --quiet "$source"
git -C "$source" remote add origin "$rpi_git_url"
git -C "$source" fetch --quiet --depth 1 origin "$rpi_head"
git -C "$source" checkout --quiet --detach FETCH_HEAD
[[ $(git -C "$source" rev-parse HEAD) == "$rpi_head" ]] || die "Raspberry Pi source revision mismatch"
git -C "$source" apply --check "$root/patches/kernel.patch"
git -C "$source" apply "$root/patches/kernel.patch"

make -C "$source" O="$build" ARCH=arm64 bcm2711_defconfig
while IFS= read -r option; do
    [[ -z $option || $option == \#* ]] && continue
    read -r -a arguments <<< "$option"
    "$source/scripts/config" --file "$build/.config" "${arguments[@]}"
done < "$root/configs/proxmox.opts"
make -C "$source" O="$build" ARCH=arm64 olddefconfig
while read -r action symbol value; do
    [[ -z $action || $action == \#* ]] && continue
    case "$action" in
        -e) expected="$symbol=y" ;;
        -m) expected="$symbol=m" ;;
        -d) expected="# $symbol is not set" ;;
        --set-str) expected="$symbol=\"$value\"" ;;
        *) die "unsupported kernel option action: $action" ;;
    esac
    grep -qxF "$expected" "$build/.config" || die "kernel configuration did not retain $expected"
done < "$root/configs/proxmox.opts"
# Raspberry Pi's defconfig owns the hardware suffix (for example, -v8).
# A build-tree localversion file prefixes it without replacing that suffix.
printf '%s\n' '-rpi' > "$build/localversion-pmx"

kernel_base=$(make -s -C "$source" O="$build" ARCH=arm64 LOCALVERSION='' kernelrelease)
[[ $kernel_base == *-rpi-"$rpi_flavour" ]] || die "unexpected kernel release: $kernel_base"
timestamp=${KBUILD_BUILD_VERSION_TIMESTAMP:-"PMX ${kernel_base%-rpi-*} ($(date -u +%Y-%m-%dT%H:%MZ))"}
export KBUILD_BUILD_VERSION=${KBUILD_BUILD_VERSION:-1}
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-$timestamp}
export KBUILD_BUILD_VERSION_TIMESTAMP=$timestamp
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$source" show -s --format=%ct HEAD)}

make -C "$source" O="$build" ARCH=arm64 LOCALVERSION='' -j"$jobs" Image modules dtbs modules_prepare

git clone --quiet --depth 1 --branch "$zfs_ref" https://github.com/openzfs/zfs.git "$zfs"
(
    cd "$zfs"
    sh autogen.sh
    ./configure --with-linux="$source" --with-linux-obj="$build"
    make -j"$jobs"
)

version=$(make -s -C "$source" O="$build" ARCH=arm64 LOCALVERSION='' kernelrelease)
package="$output/stage/linux-image-$version"
firmware="$package/usr/lib/linux-image-$version"
dtbs="$build/arch/arm64/boot/dts"
overlay_readme="$source/arch/arm64/boot/dts/overlays/README"

for required in \
    "$build/arch/arm64/boot/Image" \
    "$dtbs/broadcom/bcm2711-rpi-4-b.dtb" \
    "$overlay_readme" \
    "$zfs/module/spl.ko" \
    "$zfs/module/zfs.ko"; do
    [[ -f $required ]] || die "missing build artifact: $required"
done

rm -rf "$output/stage"
mkdir -p "$package/DEBIAN" "$firmware/broadcom" "$firmware/overlays"
install -D -m 0644 "$build/.config" "$package/boot/config-$version"
install -D -m 0644 "$build/System.map" "$package/boot/System.map-$version"
gzip -n -9 -c "$build/arch/arm64/boot/Image" > "$package/boot/vmlinuz-$version"
install -m 0644 "$dtbs/broadcom/"*.dtb "$firmware/broadcom/"
install -m 0644 "$dtbs/overlays/"*.dtbo "$dtbs/overlays/"*.dtb "$firmware/overlays/"
install -m 0644 "$overlay_readme" "$firmware/overlays/README"
make -C "$source" O="$build" ARCH=arm64 LOCALVERSION='' DEPMOD=/bin/true INSTALL_MOD_PATH="$package" modules_install
install -D -m 0644 "$zfs/module/spl.ko" "$package/lib/modules/$version/updates/zfs/spl.ko"
install -D -m 0644 "$zfs/module/zfs.ko" "$package/lib/modules/$version/updates/zfs/zfs.ko"

cat > "$package/DEBIAN/control" <<EOF
Package: linux-image-$version
Version: $version
Section: kernel
Priority: optional
Architecture: arm64
Maintainer: Proxmox Raspberry Build <root@localhost>
Depends: initramfs-tools, kmod, zfs-initramfs, zfsutils-linux (>= $zfs_version), zfsutils-linux (<< ${zfs_version%.*}.$((${zfs_version##*.} + 1)))
Provides: zfs-modules
Description: Raspberry Pi 4 Proxmox kernel and OpenZFS modules $version
 Custom Raspberry Pi kernel with Proxmox host features and matched OpenZFS modules.
EOF

cat > "$package/DEBIAN/postinst" <<EOF
#!/bin/sh
set -eu
version=$version
image=/boot/vmlinuz-\$version

depmod "\$version"
if [ -e /boot/initrd.img-\$version ]; then
    update-initramfs -u -k "\$version"
else
    update-initramfs -c -k "\$version"
fi

DEB_MAINT_PARAMS=configure run-parts --verbose --exit-on-error \\
    --arg="\$version" --arg="\$image" /etc/kernel/postinst.d
EOF
chmod 0755 "$package/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$package" "$output/linux-image-${version}.deb"
