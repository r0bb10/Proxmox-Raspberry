#!/usr/bin/env bash
set -euo pipefail

root=$(realpath "$(dirname "$0")/..")
platform=${PVE_PLATFORM:-pi4}
rootfs_type=${PVE_ROOTFS:-ext4}
kernel_deb=${PVE_KERNEL_DEB:-}
output=""
stage=all
reset=0

usage() {
    cat <<EOF
usage: $0 --kernel-deb PATH [--platform pi4|pi5] [--rootfs ext4|zfs] [--output PATH] [--stage STAGE] [--reset]

Stages: bootstrap, proxmox, configure, assemble, all, clean
The clean stage does not require --kernel-deb.
EOF
}

while (($#)); do
    case "$1" in
        --platform) platform=${2:?missing value for --platform}; shift 2 ;;
        --rootfs) rootfs_type=${2:?missing value for --rootfs}; shift 2 ;;
        --kernel-deb) kernel_deb=${2:?missing value for --kernel-deb}; shift 2 ;;
        --output) output=${2:?missing value for --output}; shift 2 ;;
        --stage) stage=${2:?missing value for --stage}; shift 2 ;;
        --reset) reset=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
case "$stage" in
    bootstrap|proxmox|configure|assemble|all|clean) ;;
    *) die "unknown stage: $stage" ;;
esac
case "$platform" in
    pi4)
        kernel_modules_suffix=-rpi-v8
        boot_kernel=kernel8.img
        boot_initramfs=initramfs8
        boot_dtb=bcm2711-rpi-4-b.dtb
        ;;
    pi5)
        kernel_modules_suffix=-rpi-2712
        boot_kernel=kernel_2712.img
        boot_initramfs=initramfs_2712
        boot_dtb=bcm2712-rpi-5-b.dtb
        ;;
    *) die "platform must be pi4 or pi5" ;;
esac
case "$rootfs_type" in
    ext4|zfs) ;;
    *) die "rootfs must be ext4 or zfs" ;;
esac
[[ -n $output ]] || output="$root/dist/proxmox-ve-$platform-$rootfs_type.img"
[[ $(id -u) -eq 0 ]] || die "run as root"
command -v umount >/dev/null || die "missing command: umount"
if [[ $stage != clean ]]; then
    [[ -f $kernel_deb ]] || die "--kernel-deb must name an existing package"
    for command in curl debootstrap dpkg-deb du gpg losetup mkfs.vfat mount parted partprobe rsync sha256sum; do
        command -v "$command" >/dev/null || die "missing command: $command"
    done
    if [[ $rootfs_type == ext4 ]]; then
        command -v mkfs.ext4 >/dev/null || die "missing command: mkfs.ext4"
    else
        for command in zfs zgenhostid zpool; do
            command -v "$command" >/dev/null || die "missing command: $command"
        done
    fi

    kernel_package=$(dpkg-deb -f "$kernel_deb" Package)
    kernel_package_version=$(dpkg-deb -f "$kernel_deb" Version)
    kernel_package_architecture=$(dpkg-deb -f "$kernel_deb" Architecture)
    kernel_package_sha256=$(sha256sum "$kernel_deb" | cut -d' ' -f1)
    [[ $kernel_package == linux-image-* ]] || die "kernel package must be named linux-image-*"
    [[ $kernel_package_architecture == arm64 ]] || die "kernel package must target arm64"
    case "$platform" in
        pi4) [[ $kernel_package_version == *-rpi-v8 ]] || die "kernel package is not a Pi 4 rpi-v8 build" ;;
        pi5) [[ $kernel_package_version == *-rpi-2712 ]] || die "kernel package is not a Pi 5 rpi-2712 build" ;;
    esac
fi

work=${WORKDIR:-"$root/.dev/$platform-$rootfs_type-image-build"}
rootfs="$work/rootfs"
state="$work/.state"
root_min_gib=${IMG_ROOT_GIB:-0}
root_reserve_gib=${IMG_ROOT_RESERVE_GIB:-1}
root_align_mib=${IMG_ROOT_ALIGN_MIB:-256}
mirror=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
proxmox_key_url=${PROXMOX_KEY_URL:-https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg}
raspi_key_url=${RASPI_KEY_URL:-https://archive.raspberrypi.com/debian/raspberrypi.gpg.key}
raspi_repo=${RASPI_REPO:-https://archive.raspberrypi.com/debian}
root_password=${PVE_ROOT_PASSWORD:-}
hostname=${PVE_HOSTNAME:-}
domain=${PVE_DOMAIN:-}
ipv4_cidr=${PVE_IPV4_CIDR:-}
gateway=${PVE_GATEWAY:-}
dns_server=${PVE_DNS_SERVER:-}
fqdn=""
loop=""
zpool_created=0

[[ $root_min_gib =~ ^[0-9]+$ ]] || die "IMG_ROOT_GIB must be a non-negative integer"
[[ $root_reserve_gib =~ ^[0-9]+$ ]] || die "IMG_ROOT_RESERVE_GIB must be a non-negative integer"
[[ $root_align_mib =~ ^[1-9][0-9]*$ ]] || die "IMG_ROOT_ALIGN_MIB must be a positive integer"

mark() { touch "$state/$1"; }
complete() { [[ -e "$state/$1" ]]; }
configuration_digest() {
    printf '%s\0' \
        "$platform" "$rootfs_type" "$mirror" "$proxmox_key_url" "$raspi_key_url" "$raspi_repo" \
        "$kernel_package" "$kernel_package_version" "$kernel_package_sha256" \
        "$root_password" "$hostname" "$domain" "$ipv4_cidr" "$gateway" "$dns_server" \
        "$root_min_gib" "$root_reserve_gib" "$root_align_mib" |
        sha256sum | cut -d' ' -f1
}
validate_build_state() {
    local digest saved_digest stage_marker
    digest=$(configuration_digest)
    mkdir -p "$state"
    if [[ -e $state/config.sha256 ]]; then
        saved_digest=$(<"$state/config.sha256")
        [[ $saved_digest == "$digest" ]] || die "build configuration changed; rerun with --reset or use a different WORKDIR"
    else
        for stage_marker in bootstrap proxmox configure assemble; do
            [[ ! -e $state/$stage_marker ]] || die "existing build state has no configuration record; rerun with --reset"
        done
        printf '%s\n' "$digest" > "$state/config.sha256"
    fi
}
valid_ipv4() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}
valid_domain() {
    local label
    local -a labels
    IFS=. read -r -a labels <<<"$1"
    ((${#labels[@]} > 0)) || return 1
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}
validate_configuration() {
    local address prefix extra
    [[ -n $root_password && $root_password != *:* && $root_password != *$'\n'* ]] || die "PVE_ROOT_PASSWORD must not be empty or contain ':'"
    [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid PVE_HOSTNAME"
    valid_domain "$domain" || die "invalid PVE_DOMAIN"
    IFS=/ read -r address prefix extra <<<"$ipv4_cidr"
    [[ -n $address && -n $prefix && -z ${extra:-} && $prefix =~ ^[0-9]+$ ]] || die "PVE_IPV4_CIDR must be an IPv4 address with a prefix length"
    if ! valid_ipv4 "$address" || ((10#$prefix > 32)); then
        die "invalid PVE_IPV4_CIDR"
    fi
    valid_ipv4 "$gateway" || die "invalid PVE_GATEWAY"
    valid_ipv4 "$dns_server" || die "invalid PVE_DNS_SERVER"
    fqdn="$hostname.$domain"
}
chroot_exec() {
    chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 "$@"
}
mount_chroot() {
    mkdir -p "$rootfs"/{proc,sys,dev}
    for directory in proc sys dev; do
        mountpoint -q "$rootfs/$directory" || {
            mount --rbind "/$directory" "$rootfs/$directory"
            mount --make-rslave "$rootfs/$directory"
        }
    done
}
unmount_chroot() {
    umount -R -f "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" 2>/dev/null || true
}
cleanup() {
    unmount_chroot
    if [[ -n $loop ]]; then
        umount -f "$work/mnt-boot" "$work/mnt-root" 2>/dev/null || true
        if ((zpool_created)); then
            zpool export rpool 2>/dev/null || true
        fi
        losetup -d "$loop" 2>/dev/null || true
    fi
}
trap cleanup EXIT

write_target_identity() {
    printf '%s\n' "$hostname" > "$rootfs/etc/hostname"
    cat > "$rootfs/etc/hosts" <<EOF
127.0.0.1 localhost.localdomain localhost
::1 localhost ip6-localhost ip6-loopback
${ipv4_cidr%/*} $fqdn $hostname
EOF
    printf '%s\n' "$fqdn" > "$rootfs/etc/mailname"
    mkdir -p "$rootfs/etc/network"
    cat > "$rootfs/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

iface eth0 inet manual

auto vmbr0
iface vmbr0 inet static
    address $ipv4_cidr
    gateway $gateway
    dns-nameservers $dns_server
    bridge-ports eth0
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
EOF
    printf 'root:%s\n' "$root_password" | chroot_exec chpasswd
}
write_target_dns() {
    cat > "$rootfs/etc/resolv.conf" <<EOF
search $domain
nameserver $dns_server
EOF
}
kernel_release() {
    local -a modules=("$rootfs"/lib/modules/*"$kernel_modules_suffix")
    [[ -d ${modules[0]} ]] || die "Raspberry Pi $platform kernel modules missing"
    ((${#modules[@]} == 1)) || die "expected one Raspberry Pi $platform kernel release"
    basename "${modules[0]}"
}
clean() {
    unmount_chroot
    rm -rf "$work"
}

install_pve_firmware_placeholder() {
    local package_dir version

    version=$(chroot_exec apt-cache show pve-firmware | sed -n 's/^Version: //p' | sort -V | tail -n 1)
    [[ -n $version ]] || die "could not determine the pve-firmware version"

    package_dir=/tmp/pve-firmware-placeholder
    rm -rf "$rootfs$package_dir"
    mkdir -p "$rootfs$package_dir/DEBIAN"
    cat > "$rootfs$package_dir/DEBIAN/control" <<EOF
Package: pve-firmware
Version: ${version}+rpi1
Architecture: all
Maintainer: Proxmox Raspberry Build <root@localhost>
Description: Placeholder for Proxmox firmware on Raspberry Pi
 The Raspberry Pi image uses firmware-brcm80211, which conflicts with the
 official pve-firmware package. This package intentionally contains no files.
EOF
    chroot_exec dpkg-deb --root-owner-group --build "$package_dir" /tmp/pve-firmware-placeholder.deb >/dev/null
    chroot_exec dpkg -i /tmp/pve-firmware-placeholder.deb
    rm -rf "$rootfs$package_dir" "$rootfs/tmp/pve-firmware-placeholder.deb"
}

bootstrap() {
    complete bootstrap && return
    mkdir -p "$work" "$state"
    if [[ ! -x "$rootfs/usr/bin/apt-get" ]]; then
        debootstrap --arch=arm64 --variant=minbase trixie "$rootfs" "$mirror"
    fi
    mount_chroot
    write_target_identity
    cp /etc/resolv.conf "$rootfs/etc/resolv.conf"
    cat > "$rootfs/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 0755 "$rootfs/usr/sbin/policy-rc.d"
    mkdir -p "$rootfs/etc/apt/sources.list.d"
    rm -f "$rootfs/etc/apt/sources.list"
    cat > "$rootfs/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $mirror
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq ca-certificates gnupg
    mkdir -p "$rootfs/etc/apt/keyrings" "$rootfs/boot/firmware"
    cat > "$rootfs/etc/apt/apt.conf.d/99-raspberrypi-gpgv" <<'EOF'
// The Raspberry Pi archive key has a legacy SHA-1 self-signature. Debian
// Trixie's Sequoia verifier rejects that certification after 2026-02-01;
// retain release-signature verification with GnuPG's compatible verifier.
Apt::Key::gpgvcommand "/usr/bin/gpgv";
EOF
    curl -fsSL "$raspi_key_url" | gpg --dearmor > "$rootfs/etc/apt/keyrings/raspberrypi-archive-keyring.gpg"
    cat > "$rootfs/etc/apt/sources.list.d/raspi.sources" <<EOF
Types: deb
URIs: $raspi_repo
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/raspberrypi-archive-keyring.gpg
EOF
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq \
        raspi-firmware \
        raspi-utils-core raspi-utils-dt rpi-eeprom raspinfo \
        bluez-firmware firmware-brcm80211 \
        locales kmod initramfs-tools openssh-server chrony cron postfix \
        console-setup keyboard-configuration ipvsadm iputils-ping nano dialog \
        parted bsdextrautils tar dosfstools e2fsprogs fdisk util-linux rsync
    install -D -m 0644 "$kernel_deb" "$rootfs/tmp/$kernel_package.deb"
    chroot_exec apt-get install -y -qq "/tmp/$kernel_package.deb"
    rm -f "$rootfs/tmp/$kernel_package.deb"
    mark bootstrap
}

proxmox() {
    complete proxmox && return
    complete bootstrap || die "run bootstrap first"
    mount_chroot
    mkdir -p "$rootfs/etc/apt/preferences.d"
    curl -fsSL "$proxmox_key_url" -o "$rootfs/etc/apt/keyrings/proxmox-archive-keyring.gpg"
    cat > "$rootfs/etc/apt/sources.list.d/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Architectures: arm64 amd64
Signed-By: /etc/apt/keyrings/proxmox-archive-keyring.gpg
EOF
    cat > "$rootfs/etc/apt/preferences.d/no-proxmox-kernels" <<'EOF'
Package: proxmox-ve proxmox-default-kernel proxmox-kernel-* linux-image-rpi-v8 linux-image-rpi-2712 linux-image-rpi-*-rt linux-image-*-rpi-*-rt linux-headers-rpi-*-rt linux-headers-*-rpi-*-rt
Pin: version *
Pin-Priority: -1
EOF
    cat > "$rootfs/etc/apt/preferences.d/pve-firmware-rpi" <<'EOF'
Package: pve-firmware
Pin: version *
Pin-Priority: -1
EOF
    chroot_exec apt-get update -qq
    chroot_exec apt-get install -y -qq proxmox-archive-keyring
    rm -f "$rootfs/etc/apt/keyrings/proxmox-archive-keyring.gpg"
    sed -i 's|/etc/apt/keyrings/proxmox-archive-keyring.gpg|/usr/share/keyrings/proxmox-archive-keyring.gpg|' "$rootfs/etc/apt/sources.list.d/proxmox.sources"
    chroot_exec apt-get install -y -qq \
        ifupdown2 ksm-control-daemon pve-manager pve-qemu-kvm qemu-server \
        pve-edk2-firmware pve-edk2-firmware-aarch64 isc-dhcp-client
    chroot_exec apt-get purge -y -qq pve-firmware
    install_pve_firmware_placeholder
    mark proxmox
}

configure() {
    complete configure && return
    complete proxmox || die "run proxmox first"
    mount_chroot
    local release
    release=$(kernel_release)
    boot="$rootfs/boot/firmware"
    [[ -s "$boot/$boot_kernel" ]] || die "Raspberry Pi $platform kernel missing"
    [[ -s "$boot/$boot_initramfs" ]] || die "Raspberry Pi $platform initramfs missing"
    [[ -s "$boot/start4.elf" ]] || die "Raspberry Pi firmware missing"
    [[ -s "$boot/$boot_dtb" ]] || die "Raspberry Pi $platform DTB missing"
    [[ -d "$boot/overlays" ]] || die "Raspberry Pi overlays missing"
    if [[ $rootfs_type == ext4 ]]; then
        [[ -s "$state/root-uuid" ]] || cat /proc/sys/kernel/random/uuid > "$state/root-uuid"
        root_uuid=$(<"$state/root-uuid")
        root_fstab="UUID=$root_uuid / ext4 defaults,noatime 0 1"
        root_cmdline="root=UUID=$root_uuid rootfstype=ext4 rootwait fsck.repair=yes"
    else
        root_fstab="# Root filesystem is rpool/ROOT/pve-1."
        root_cmdline="root=ZFS=rpool/ROOT/pve-1"
    fi
    cat > "$rootfs/etc/fstab" <<EOF
$root_fstab
LABEL=BOOT /boot/firmware vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
    cat > "$boot/config.txt" <<'EOF'
# For more options and information see
# http://rptl.io/configtxt
# Some settings may impact device functionality. See link above for details

# Uncomment some or all of these to enable the optional hardware interfaces
#dtparam=i2c_arm=on
#dtparam=i2s=on
#dtparam=spi=on

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

# Additional overlays and parameters are documented
# /boot/firmware/overlays/README

# Automatically load overlays for detected cameras
camera_auto_detect=1

# Automatically load overlays for detected DSI displays
display_auto_detect=1

# Automatically load initramfs files, if found
auto_initramfs=1

# Enable DRM VC4 V3D driver
dtoverlay=vc4-kms-v3d
max_framebuffers=2

# Don't have the firmware create an initial video= setting in cmdline.txt.
# Use the kernel's default instead.
disable_fw_kms_setup=1

# Run in 64-bit mode
arm_64bit=1

# Disable compensation for displays with overscan
disable_overscan=1

# Run as fast as firmware / board allows
arm_boost=1

[cm4]
# Enable host mode on the 2711 built-in XHCI USB controller.
# This line should be removed if the legacy DWC2 controller is required
# (e.g. for USB device mode) or if USB support is not required.
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[pi5]
dtoverlay=nospi10

[all]
# PVE image settings: expose the serial console and select the target kernel.
enable_uart=1
EOF
    printf 'kernel=%s\n' "$boot_kernel" >> "$boot/config.txt"
    cat > "$boot/cmdline.txt" <<EOF
console=serial0,115200 console=tty1 $root_cmdline net.ifnames=0 cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1
EOF
    mkdir -p "$rootfs/etc/ssh/sshd_config.d"
    rm -f "$rootfs/etc/network/interfaces.new"
    printf 'PermitRootLogin yes\n' > "$rootfs/etc/ssh/sshd_config.d/99-root.conf"
    cat > "$rootfs/etc/modprobe.d/zfs.conf" <<'EOF'
# Preserve enough memory for PVE services on lower-memory Raspberry Pi variants.
options zfs zfs_arc_max=1073741824
EOF
    write_target_dns
    chroot_exec postconf -e "myhostname = $fqdn"
    chroot_exec postconf -e 'inet_interfaces = loopback-only'
    chroot_exec postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost"
    : > "$rootfs/etc/machine-id"
    rm -f "$rootfs/var/lib/dbus/machine-id"
    ln -s /etc/machine-id "$rootfs/var/lib/dbus/machine-id"
    chroot_exec debconf-set-selections <<<'debconf debconf/frontend select Noninteractive'
    printf 'LANG=C.UTF-8\n' > "$rootfs/etc/default/locale"
    chroot_exec locale-gen C.UTF-8
    [[ -s "$rootfs/lib/modules/$release/updates/zfs/spl.ko" ]] || die "built-in SPL module missing for $release"
    [[ -s "$rootfs/lib/modules/$release/updates/zfs/zfs.ko" ]] || die "built-in ZFS module missing for $release"
    rm -f "$rootfs/etc/pve/local/"*.pem
    rm -f "$rootfs/usr/sbin/policy-rc.d"
    chroot_exec apt-get clean
    rm -rf "$rootfs/var/lib/apt/lists/"*
    mark configure
}

assemble() {
    complete configure || die "run configure first"
    boot="$rootfs/boot/firmware"
    [[ -s "$boot/$boot_kernel" && -s "$boot/$boot_initramfs" && -s "$boot/config.txt" && -s "$boot/cmdline.txt" ]] || die "Raspberry Pi boot payload incomplete"
    image="$work/image.img"
    rm -f "$image" "$output"
    root_bytes=$(du -sx --apparent-size --block-size=1 "$rootfs" | cut -f1)
    root_bytes=$((root_bytes + root_reserve_gib * 1024 * 1024 * 1024))
    root_min_bytes=$((root_min_gib * 1024 * 1024 * 1024))
    ((root_bytes >= root_min_bytes)) || root_bytes=$root_min_bytes
    root_align_bytes=$((root_align_mib * 1024 * 1024))
    root_bytes=$(((root_bytes + root_align_bytes - 1) / root_align_bytes * root_align_bytes))
    image_bytes=$((512 * 1024 * 1024 + root_bytes))
    truncate -s "$image_bytes" "$image"
    parted -s "$image" mklabel msdos mkpart primary fat32 4MiB 516MiB set 1 lba on mkpart primary 516MiB 100%
    loop=$(losetup -Pf --show "$image")
    for _ in {1..10}; do
        [[ -b "${loop}p1" && -b "${loop}p2" ]] && break
        partprobe "$loop"
        sleep 1
    done
    [[ -b "${loop}p1" && -b "${loop}p2" ]] || die "loop partitions did not appear"
    mkdir -p "$work/mnt-boot" "$work/mnt-root"
    mkfs.vfat -F 32 -n BOOT "${loop}p1"
    if [[ $rootfs_type == ext4 ]]; then
        root_uuid=$(<"$state/root-uuid")
        mkfs.ext4 -F -q -U "$root_uuid" -L rootfs "${loop}p2"
        mount "${loop}p2" "$work/mnt-root"
    else
        zpool list rpool >/dev/null 2>&1 && die "refusing to use existing ZFS pool: rpool"
        zpool create -f -R "$work/mnt-root" -o ashift=12 -o cachefile=none \
            -O mountpoint=none -O compression=lz4 -O atime=off -O acltype=posixacl rpool "${loop}p2"
        zpool_created=1
        zfs create -o mountpoint=none rpool/ROOT
        zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/pve-1
        zfs mount rpool/ROOT/pve-1
    fi
    rsync -aHAX --numeric-ids --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/tmp/*' --exclude='/boot/firmware/*' "$rootfs/" "$work/mnt-root/"
    mkdir -p "$work/mnt-root"/{dev,proc,sys,tmp,boot/firmware}
    chmod 1777 "$work/mnt-root/tmp"
    if [[ $rootfs_type == zfs ]]; then
        mkdir -p "$work/mnt-root/etc/zfs"
        zpool set cachefile="$work/mnt-root/etc/zfs/zpool.cache" rpool
        chroot "$work/mnt-root" zgenhostid -f "$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
        cp "$work/mnt-root/etc/hostid" "$rootfs/etc/hostid"
        mkdir -p "$rootfs/etc/zfs"
        cp "$work/mnt-root/etc/zfs/zpool.cache" "$rootfs/etc/zfs/zpool.cache"
        chroot_exec update-initramfs -u -k "$(kernel_release)"
        zfs unmount -f rpool/ROOT/pve-1
        if ! zpool export -f rpool; then
            die "could not export temporary ZFS pool"
        fi
        zpool_created=0
    else
        umount "$work/mnt-root"
    fi
    mount "${loop}p1" "$work/mnt-boot"
    cp -a "$boot/." "$work/mnt-boot/"
    umount "$work/mnt-boot"
    losetup -d "$loop"
    loop=""
    mkdir -p "$(dirname "$output")"
    mv "$image" "$output"
    mark assemble
    printf 'Built %s\n' "$output"
}

if [[ $stage != clean ]]; then
    validate_configuration
fi
if ((reset)); then
    clean
fi
if [[ $stage != clean ]]; then
    validate_build_state
fi
case "$stage" in
    bootstrap) bootstrap ;;
    proxmox) proxmox ;;
    configure) configure ;;
    assemble) assemble ;;
    all) bootstrap; proxmox; configure; assemble ;;
    clean) clean ;;
esac
