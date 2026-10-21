#!/bin/sh
# Keep the previous installed kernel bootable without relying on APT/network.
set -eu
new=${1:?kernel release required}
case "$new" in
    *-rpi-v8) flavour=v8; image=kernel8.img; initrd=initramfs8; dtb=bcm2711-rpi-4-b.dtb ;;
    *-rpi-2712) flavour=2712; image=kernel_2712.img; initrd=initramfs_2712; dtb=bcm2712-rpi-5-b.dtb ;;
    *) exit 0 ;;
esac
boot=/boot/firmware
test -s "$boot/config.txt" || exit 0
previous=$(find /boot -maxdepth 1 -name "vmlinuz-*-rpi-$flavour" | sed 's|/boot/vmlinuz-||' | grep -vxF "$new" | sort -V | tail -n 1)
test -n "$previous" || exit 0
test -s "/boot/initrd.img-$previous"
firmware=/usr/lib/linux-image-$previous
test -s "$firmware/broadcom/$dtb"
mkdir -p "$boot/rollback/overlays"
cp "/boot/vmlinuz-$previous" "$boot/rollback/$image"
cp "/boot/initrd.img-$previous" "$boot/rollback/$initrd"
cp "$firmware/broadcom/"*.dtb "$boot/rollback/"
cp "$firmware/overlays/"*.dtb* "$boot/rollback/overlays/"
cp "$boot/config.txt" "$boot/config-rollback.txt"
cat >> "$boot/config-rollback.txt" <<EOF

[all]
# Offline rollback: copy this file over config.txt on the boot partition.
auto_initramfs=0
kernel=rollback/$image
initramfs rollback/$initrd followkernel
device_tree=rollback/$dtb
overlay_prefix=rollback/overlays/
EOF
printf '%s\n' "$previous" > "$boot/rollback/kernel-release"
# Keep both kernel packages available even if their metapackage moves on.
apt-mark manual "linux-image-$previous" "linux-image-$new" >/dev/null
sync -f "$boot"
echo "Boot fallback prepared for $previous (config-rollback.txt)."
