# Pi 4 Kernel Parity Gaps

Base: Raspberry Pi `rpi-6.18.y` Pi 4 `bcm2711_defconfig` at
`c1a5fac58f028b585ae79bcc2371d0f1f9441bd9`.

Goal: add the non-hardware PVE ARM64 configuration gaps. Keep Raspberry Pi
firmware, device-tree, SoC, storage-host, display, and other board settings.

## Enable

### VM Memory And Virtualization

```text
CONFIG_KSM=y
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=n
CONFIG_HUGETLBFS=y
CONFIG_HUGETLB_PAGE=y
CONFIG_KVM=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_TARGET_CORE=m
CONFIG_VDPA=m
CONFIG_VHOST_SCSI=m
CONFIG_VHOST_VDPA=m
CONFIG_VIRTIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_FS=m
CONFIG_VIRTIO_VSOCKETS=m
```

### LXC And Cgroups

```text
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
CONFIG_MEMCG_V1=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_HUGETLB=y
CONFIG_CGROUP_MISC=y
CONFIG_CGROUP_RDMA=y
CONFIG_NAMESPACES=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_VETH=m
CONFIG_VLAN_8021Q=m
CONFIG_OVERLAY_FS=m
CONFIG_OVERLAY_FS_XINO_AUTO=y
```

### Security

```text
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_LSM="lockdown,yama,integrity,apparmor"
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LANDLOCK=y
CONFIG_SECURITY_SAFESETID=y
CONFIG_SECURITY_DMESG_RESTRICT=y
CONFIG_IMA=y
CONFIG_EVM=y
CONFIG_MODVERSIONS=y
```

Do not enable kernel module signing in the first release: no protected project
signing key exists yet. This is the only planned PVE security-policy exception.

### Firewall And Bridges

```text
CONFIG_IPV6=y
CONFIG_NETFILTER=y
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_TUN=y
CONFIG_NETWORK_SECMARK=y
CONFIG_NFT_BRIDGE_META=m
CONFIG_NF_CONNTRACK_BRIDGE=m
CONFIG_NF_CONNTRACK_SECMARK=y
CONFIG_NF_CONNTRACK_TIMEOUT=y
CONFIG_NF_CT_NETLINK_HELPER=m
CONFIG_NF_CT_NETLINK_TIMEOUT=m
CONFIG_NETFILTER_NETLINK_GLUE_CT=y
CONFIG_NETFILTER_NETLINK_HOOK=m
CONFIG_NETFILTER_XTABLES=m
CONFIG_NETFILTER_XTABLES_LEGACY=y
CONFIG_IP_NF_IPTABLES=m
CONFIG_IP_NF_IPTABLES_LEGACY=m
CONFIG_IP_NF_RAW=m
CONFIG_IP6_NF_IPTABLES=m
CONFIG_IP6_NF_IPTABLES_LEGACY=m
CONFIG_IP6_NF_RAW=m
CONFIG_BRIDGE_NF_EBTABLES_LEGACY=m
CONFIG_BRIDGE_EBT_T_FILTER=m
CONFIG_NFT_COMPAT=m
```

The stock Pi config already has nftables and `nft_compat`. Keep both.

### Storage

```text
CONFIG_BLK_DEV_DM=y
CONFIG_BLK_DEV_UBLK=m
CONFIG_FUSE_FS=y
CONFIG_SQUASHFS=y
CONFIG_CEPH_FSCACHE=y
CONFIG_CEPH_FS_POSIX_ACL=y
CONFIG_CEPH_FS_SECURITY_LABEL=y
```

## Exclude

Do not add VFIO/IOMMU features. Pi 4 has no useful PVE passthrough path.

Do not copy source-version-only PVE 7.0 symbols that do not exist in Pi 6.18.
`CONFIG_DEFAULT_SECURITY_APPARMOR`, `CONFIG_DEFAULT_SECURITY`, and
`CONFIG_MEMCG_SWAP_ENABLED` are unavailable in this source; the 6.18
equivalents above are enabled.

## ZFS

OpenZFS `2.4.4` was fetched from the official release tarball and verified
against its published SHA-256. It was cross-built as prebuilt external modules
against the exact `6.18.52+` kernel build tree.

```text
Source:  work/zfs-2.4.4/
Modules: work/zfs-2.4.4/module/zfs.ko
         work/zfs-2.4.4/module/spl.ko
Vermagic: 6.18.52+ SMP preempt mod_unload modversions aarch64
```

The initial cross-build incorrectly ran OpenZFS's CPU probes with the x86 host
compiler, which selected x86 AVX/SSE Fletcher symbols. Reconfiguring with
`CC=aarch64-linux-gnu-gcc --host=aarch64-linux-gnu` selected the ARM64 code
paths and completed cleanly.

Package the modules with an exact dependency on `6.18.52+`. Do not install
`zfs-dkms`.

## Build Status

The direct ARM64 cross-build configuration resolved the original `78/78`
requested settings. It was compiled successfully with
`aarch64-linux-gnu-`.

```text
Kernel release: 6.18.52+
Kernel image:   arch/arm64/boot/Image
Pi 4 DTB:       arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb
Modules:        1,933
```

Verified compiled modules include `ip_tables.ko`, `vhost_scsi.ko`, and
`vhost_vdpa.ko`.

### Pending Kernel Metadata And Firewall Revision

The first successful `6.18.52+` build omitted `iptable_raw.ko` and
`ip6table_raw.ko`. PVE firewall applies `raw` table transactions, so the
configuration list now has 80 settings including `CONFIG_IP_NF_RAW=m` and
`CONFIG_IP6_NF_RAW=m`. Those two local config changes were made, but the
follow-up `olddefconfig` and rebuild were intentionally stopped before they
ran.

PVE Manager displays `(unknown)` for the current kernel because its UI extracts
the build date from a final parenthesized value in `uname -v`. The upstream Pi
kernel does not include PVE's `KBUILD_BUILD_VERSION_TIMESTAMP` patch. Before
the next compile, apply
`patches/kernel/0001-Make-mkcompile_h-accept-an-alternate-timestamp-strin.patch`
from `work/pve-kernel-audit`, then build with a value such as:

```text
KBUILD_BUILD_VERSION_TIMESTAMP="PVE 6.18.52+ (2026-09-22T20:28Z)"
```

This yields a PVE-style `uname -v` string and lets the UI show the build date.
`CONFIG_BUILD_SALT` does not affect this field.

`configs/proxmox.opts` retains the same configuration set for the future PVE
package-build path; it was not used for this direct cross-build.

## Target Pi Packaging Constraints

Audited target: `root@10.0.0.9`, Raspberry Pi 4 running Debian 13 ARM64.

```text
Running kernel: 6.18.50+rpt-rpi-v8
Root dataset:   rpool/ROOT/pve-1
Root vdev:      /dev/sda2
Boot partition: /dev/sda1 mounted at /boot/firmware
Boot files:     /boot/firmware/kernel8.img and /boot/firmware/initramfs8
Current ZFS:    2.4.4 via zfs-dkms
```

The root filesystem is ZFS. Its initramfs contains `spl.ko`, `zfs.ko`, the
ZFS initramfs scripts, and the `zfs` and `zpool` binaries. `zfsutils-linux`
and `zfs-initramfs` are already installed at version 2.4.4 and should remain
installed. Do not remove `zfs-dkms` until the replacement kernel, external
modules, and initramfs are installed and verified.

The package installation order must be:

1. Install the `6.18.52+` kernel modules and headers.
2. Install `spl.ko` and `zfs.ko` under
   `/lib/modules/6.18.52+/updates/`, then run `depmod 6.18.52+`.
3. Generate `/boot/initrd.img-6.18.52+` with `zfs-initramfs`; verify it
   contains both ZFS modules, scripts, and utilities.
4. Install the Pi firmware boot artifacts as `kernel8.img` and `initramfs8`.
   These are separate from the versioned `/boot` files and are what firmware
   actually loads.
5. Reboot and verify the new kernel imports `rpool` and mounts
   `rpool/ROOT/pve-1` before purging `zfs-dkms`.

## Deployment Status

The matched ARM64 packages were built locally:

```text
.artifacts/packages/proxmox-rpi-kernel_6.18.52+_arm64.deb
.artifacts/packages/proxmox-rpi-zfs-kmod_2.4.4-1_arm64.deb
```

Both packages are installed on `10.0.0.9`. The active firmware
`kernel8.img`, `initramfs8`, and Pi 4 DTB match the `6.18.52+` package
artifacts. The active initramfs was checked with `lsinitramfs` and contains
the exact external `spl.ko` and `zfs.ko`, ZFS boot scripts, and `zpool`.

The stock firmware boot files are retained with the
`.pre-6.18.52+` suffix. `zfs-dkms` remains installed as the rollback path and
must not be removed until a successful boot into `6.18.52+` is confirmed.

## Verify

1. Completed: `olddefconfig` accepts all 78 requested settings.
2. Completed: build `Image`, modules, and Pi 4 DTBs.
3. Pending: build/install matching kernel headers and package the kernel,
   modules, and Pi boot artifacts.
4. Completed: cross-build OpenZFS `2.4.4` modules for `6.18.52+`.
5. Pending: package `zfs.ko` and `spl.ko` with an exact `6.18.52+` dependency.
6. On Pi: confirm KSM sysfs, ZFS root mount, Proxmox firewall, nftables,
   legacy iptables compatibility, bridges, LXC, and KVM.

## Current Revision

The follow-up revision is deployed and supersedes the pending items above:

```text
Kernel release: 6.18.52-pve-rpi-v8
ZFS vermagic:  6.18.52-pve-rpi-v8 SMP preempt mod_unload modversions aarch64
Package:       .artifacts/packages/linux-image-6.18.52-pve-rpi-v8_arm64.deb
SHA-256:       a82b9dd2c600bd296b637e10d2606d9b1aa1455bfc0880b53163017f57adaa5b
```

The package contains the kernel, all kernel modules, Pi DTBs and overlays, and
the matched OpenZFS modules. Its post-install runs `depmod`, builds the ZFS
initramfs, then invokes the Raspberry Pi firmware hook through
`/etc/kernel/postinst.d`.

On `10.0.0.9`, the Pi booted successfully into this release with
`rpool/ROOT/pve-1` mounted as root. The firmware image and initramfs match the
versioned boot artifacts, both ZFS modules load with matching vermagic, legacy
IPv4 and IPv6 raw tables work, and `pve-manager` reports the new kernel.
`zfs-dkms` was purged after successful boot verification. The unified kernel
package declares `Provides: zfs-modules`, satisfying the ZFS userspace package
dependency without DKMS.

## Next Kernel Identity

The next revision is configured locally but has not been built or deployed.
It will use the Raspberry Pi firmware-compatible release
`6.18.52-rpi-v8`, `CONFIG_PREEMPT_DYNAMIC=y`, and deterministic build metadata:

```text
KBUILD_BUILD_VERSION=1
KBUILD_BUILD_VERSION_TIMESTAMP="PMX 6.18.52 (<UTC timestamp>)"
```

This produces `#1 SMP PREEMPT_DYNAMIC PMX 6.18.52 (<UTC timestamp>)` in
`uname -v`. The current deployed release remains unchanged until a future
explicit rebuild and deployment.
