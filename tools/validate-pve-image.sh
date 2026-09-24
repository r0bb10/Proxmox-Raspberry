#!/usr/bin/env bash
set -euo pipefail

image=""

usage() {
    printf 'usage: %s --image PATH\n' "$0" >&2
}

while (($#)); do
    case "$1" in
        --image) image=${2:?missing value for --image}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

[[ -n $image && -f $image ]] || { usage; exit 2; }
[[ $(id -u) -eq 0 ]] || { printf 'error: run as root\n' >&2; exit 1; }

platform=${PVE_PLATFORM:?PVE_PLATFORM is required}
rootfs_type=${PVE_ROOTFS:?PVE_ROOTFS is required}
hostname=${PVE_HOSTNAME:?PVE_HOSTNAME is required}
domain=${PVE_DOMAIN:?PVE_DOMAIN is required}
ipv4_cidr=${PVE_IPV4_CIDR:?PVE_IPV4_CIDR is required}
gateway=${PVE_GATEWAY:?PVE_GATEWAY is required}
dns_server=${PVE_DNS_SERVER:?PVE_DNS_SERVER is required}

case "$platform" in
    pi4)
        stock_kernel_package=linux-image-rpi-v8
        boot_kernel=kernel8.img
        boot_initramfs=initramfs8
        boot_dtb=bcm2711-rpi-4-b.dtb
        ;;
    pi5)
        stock_kernel_package=linux-image-rpi-2712
        boot_kernel=kernel_2712.img
        boot_initramfs=initramfs_2712
        boot_dtb=bcm2712-rpi-5-b.dtb
        ;;
    *) printf 'error: unsupported platform: %s\n' "$platform" >&2; exit 1 ;;
esac

case "$rootfs_type" in
    ext4|zfs) ;;
    *) printf 'error: unsupported root filesystem: %s\n' "$rootfs_type" >&2; exit 1 ;;
esac

for command in blkid chroot losetup mount partprobe parted stat umount; do
    command -v "$command" >/dev/null || { printf 'error: missing command: %s\n' "$command" >&2; exit 1; }
done
if [[ $rootfs_type == zfs ]]; then
    for command in zfs zpool; do
        command -v "$command" >/dev/null || { printf 'error: missing command: %s\n' "$command" >&2; exit 1; }
    done
fi

boot=$(mktemp -d)
root=$(mktemp -d)
loop=""
zpool_imported=0

cleanup() {
    umount "$boot" "$root" 2>/dev/null || true
    if ((zpool_imported)); then
        zpool export rpool 2>/dev/null || true
    fi
    [[ -z $loop ]] || losetup -d "$loop" 2>/dev/null || true
    rm -rf "$boot" "$root"
}
trap cleanup EXIT

(( $(stat --format=%s "$image") % 512 == 0 ))
loop=$(losetup -Pf --show "$image")
for _ in {1..10}; do
    [[ -b "${loop}p1" && -b "${loop}p2" ]] && break
    partprobe "$loop"
    sleep 1
done
[[ -b "${loop}p1" && -b "${loop}p2" ]] || { printf 'error: image partitions did not appear\n' >&2; exit 1; }

mount "${loop}p1" "$boot"
[[ $(blkid -s TYPE -o value "${loop}p1") == vfat ]]
[[ $(blkid -s LABEL -o value "${loop}p1") == BOOT ]]
if [[ $rootfs_type == ext4 ]]; then
    mount "${loop}p2" "$root"
    [[ $(blkid -s TYPE -o value "${loop}p2") == ext4 ]]
    [[ $(blkid -s LABEL -o value "${loop}p2") == rootfs ]]
    root_uuid=$(blkid -s UUID -o value "${loop}p2")
else
    zpool list rpool >/dev/null 2>&1 && { printf 'error: refusing to import over existing ZFS pool: rpool\n' >&2; exit 1; }
    zpool import -N -f -R "$root" -d /dev rpool
    zpool_imported=1
    zpool status -P rpool | grep -qF "${loop}p2"
    zfs mount rpool/ROOT/pve-1
    zfs list rpool/ROOT/pve-1
fi

[[ -s $boot/start4.elf && -s $boot/fixup4.dat && -s $boot/$boot_kernel && -s $boot/$boot_initramfs && -s $boot/$boot_dtb ]]
[[ -d $boot/overlays ]]
grep -qFx 'arm_64bit=1' "$boot/config.txt"
grep -qFx 'enable_uart=1' "$boot/config.txt"
grep -qFx 'auto_initramfs=1' "$boot/config.txt"
grep -qFx "kernel=$boot_kernel" "$boot/config.txt"
[[ $(wc -l < "$boot/cmdline.txt") -eq 1 ]]
if [[ $rootfs_type == ext4 ]]; then
    grep -qF "root=UUID=$root_uuid " "$boot/cmdline.txt"
    grep -qFx "UUID=$root_uuid / ext4 defaults,noatime 0 1" "$root/etc/fstab"
else
    grep -qF 'root=ZFS=rpool/ROOT/pve-1' "$boot/cmdline.txt"
    grep -qFx '# Root filesystem is rpool/ROOT/pve-1.' "$root/etc/fstab"
    [[ -s $root/etc/hostid && -s $root/etc/zfs/zpool.cache ]]
fi
grep -qF 'console=serial0,115200' "$boot/cmdline.txt"
grep -qFx 'LABEL=BOOT /boot/firmware vfat defaults 0 2' "$root/etc/fstab"
fqdn="$hostname.$domain"
grep -qFx "$hostname" "$root/etc/hostname"
grep -qFx "${ipv4_cidr%/*} $fqdn $hostname" "$root/etc/hosts"
grep -qFx 'iface vmbr0 inet static' "$root/etc/network/interfaces"
grep -qFx "    address $ipv4_cidr" "$root/etc/network/interfaces"
grep -qFx "    gateway $gateway" "$root/etc/network/interfaces"
grep -qFx "    dns-nameservers $dns_server" "$root/etc/network/interfaces"
[[ -s $root/etc/modprobe.d/zfs.conf ]]
chroot "$root" dpkg-query -W pve-edk2-firmware pve-edk2-firmware-aarch64 bluez-firmware firmware-brcm80211
pve_firmware_version=$(chroot "$root" dpkg-query -W -f='${Version}' pve-firmware)
[[ $pve_firmware_version == *+rpi1 ]]
grep -qFx 'Package: pve-firmware' "$root/etc/apt/preferences.d/pve-firmware-rpi"
grep -qFx 'Pin: version *' "$root/etc/apt/preferences.d/pve-firmware-rpi"
grep -qFx 'Pin-Priority: -1' "$root/etc/apt/preferences.d/pve-firmware-rpi"
if chroot "$root" dpkg-query -W "$stock_kernel_package" >/dev/null 2>&1; then
    printf 'error: stock Raspberry Pi kernel package must not be installed\n' >&2
    exit 1
fi
