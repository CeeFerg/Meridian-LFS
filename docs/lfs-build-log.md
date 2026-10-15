# Meridian — A Linux From Scratch Build Log

**Builder:** Curtis Ferguson
**Distro name:** Meridian (hostname `meridian`)
**Base:** Linux From Scratch 13.1-systemd, extended with Beyond Linux From Scratch (BLFS)
**Host used for building:** Fedora 44 (KDE) on a Lenovo Legion laptop
**Status:** Boots on bare metal, Wi-Fi networking, working audio, Linux-PAM authentication with systemd-logind sessions, key-only SSH, default-deny firewall, self-hosting toolchain (C/C++/Rust/LLVM)
**Period:** October 2026

---

## Contents

1. [Overview](#1-overview)
2. [Hardware and Host Environment](#2-hardware-and-host-environment)
3. [Key Design Decisions](#3-key-design-decisions)
4. [Part I: LFS — Building the Base System](#part-i-lfs--building-the-base-system)
   - [Chapter 2: Host preparation and partitioning](#chapter-2-host-preparation-and-partitioning)
   - [Chapter 3: Source packages](#chapter-3-source-packages)
   - [Chapter 4: Build environment](#chapter-4-build-environment)
   - [Chapter 5: Cross-toolchain](#chapter-5-cross-toolchain)
   - [Chapter 6: Temporary tools](#chapter-6-temporary-tools)
   - [Chapter 7: Chroot and backup](#chapter-7-chroot-and-backup)
   - [Chapter 8: The final system](#chapter-8-the-final-system)
   - [Chapter 9: System configuration](#chapter-9-system-configuration)
   - [Chapter 10: Making it bootable](#chapter-10-making-it-bootable)
   - [Chapter 11: First boot](#chapter-11-first-boot)
5. [Part II: BLFS — Making It Usable](#part-ii-blfs--making-it-usable)
   - [Personalization: Meridian identity, console, prompt](#personalization-meridian-identity-console-prompt)
   - [Users, sudo, and shell startup files](#users-sudo-and-shell-startup-files)
   - [Certificates and HTTPS](#certificates-and-https)
   - [Wi-Fi: firmware, kernel drivers, wpa_supplicant](#wi-fi-firmware-kernel-drivers-wpa_supplicant)
   - [Graphics and regulatory firmware](#graphics-and-regulatory-firmware)
   - [First native build](#first-native-build)
   - [OpenSSH](#openssh)
   - [The Rust toolchain and Git](#the-rust-toolchain-and-git)
   - [Configuration tracking with Git](#configuration-tracking-with-git)
   - [Firewall](#firewall)
   - [Backups and recovery](#backups-and-recovery)
   - [Expanding the root partition](#expanding-the-root-partition)
   - [Audio](#audio)
   - [Linux-PAM](#linux-pam)
6. [Problems Encountered and How They Were Solved](#6-problems-encountered-and-how-they-were-solved)
7. [Security Posture](#7-security-posture)
8. [Final System Configuration](#8-final-system-configuration)
9. [Lessons Learned](#9-lessons-learned)
10. [Open Issues](#10-open-issues)
11. [Next Steps](#11-next-steps)
12. [Appendix A: Command Reference](#appendix-a-command-reference)
13. [Appendix B: What Not to Publish](#appendix-b-what-not-to-publish)

---

## 1. Overview

Linux From Scratch (LFS) is a book that walks through building a complete Linux system from source code. You compile a cross-toolchain, use it to build a temporary system, enter that system through a chroot, compile around 80 packages into the final system, configure and build your own kernel, and make it bootable. There is no package manager and no installer. Every binary on the system was compiled on this machine.

Beyond Linux From Scratch (BLFS) picks up where LFS ends. Base LFS boots to a text console with wired networking and nothing else: no Wi-Fi, no SSH, no certificates for HTTPS, no firewall, no regular user account. BLFS is a catalogue of packages with tested build instructions, and choosing what to build from it is where the system takes on its own shape.

This build was done on real hardware rather than in a virtual machine, on a dedicated partition on a second NVMe drive, dual-booted alongside Fedora. The system was named **Meridian**.

### Build time reference

LFS measures build time in SBUs (Standard Build Units), calibrated by timing the first package (Binutils Pass 1). On this machine:

```
real    1m0.166s
user    3m12.992s
sys     0m59.297s
```

**1 SBU = 60 seconds**, so SBU estimates in the book read roughly as minutes.

---

## 2. Hardware and Host Environment

| Component | Detail |
|---|---|
| Machine | Lenovo Legion laptop |
| CPU | 32 logical cores (`nproc` = 32) |
| Disk 1 (`nvme0n1`) | SK Hynix 1 TB: Fedora (LUKS2-encrypted Btrfs, EFI partition, `/boot`) |
| Disk 2 (`nvme1n1`) | Micron 512 GB: previously an unused Windows install, now Meridian |
| Wi-Fi | Intel Wi-Fi 6E AX211 (CNVi, `iwlwifi`/`iwlmvm`), PCI `00:14.3` |
| Graphics | Intel integrated (`i915`), plus a discrete GPU (`PEGP` in ACPI) not yet configured |
| Audio | Intel 700 Series HD Audio (`snd_hda_intel`), Realtek ALC257 codec; NVIDIA HDMI audio on the discrete GPU |
| Firmware | 64-bit UEFI |
| Host OS | Fedora 44 KDE, kernel 7.2.7, SELinux enforcing, root account locked |
| Host swap | zram, 8 GB |

### Disk layout before the build

```
NAME          FSTYPE   SIZE     MOUNTPOINTS
nvme0n1                953.9G
├─nvme0n1p1   vfat     600M     /boot/efi
├─nvme0n1p2   ext4     2G       /boot
└─nvme0n1p3   crypto   951.3G
  └─luks-...  btrfs             /home, /
nvme1n1                476.9G
├─nvme1n1p1            16M      (Microsoft reserved)
├─nvme1n1p2   ntfs     476.2G   (Windows)
└─nvme1n1p3   ntfs     780M     (Windows recovery)
```

### Disk layout after

Initially a 100 GB partition; later expanded to the whole drive (see [Expanding the root partition](#expanding-the-root-partition)):

```
nvme?n1                476.9G
└─nvme?n1p1   ext4     476.9G   Meridian root (label "lfs")
```

The drive appears as `nvme0n1` or `nvme1n1` depending on the boot. The names are not stable on this machine.

---

## 3. Key Design Decisions

### 3.1 Real hardware, dual boot

A VM with snapshots is the safer route for a first build. I chose a real partition so the result would be a system that actually runs on my laptop's hardware: real Wi-Fi, real GPU, real firmware quirks. Fedora stayed untouched as a fallback and as the build host.

### 3.2 Use the second NVMe instead of shrinking Fedora

The Fedora disk was entirely consumed by a LUKS-encrypted Btrfs volume. Making room would have meant shrinking Btrfs, then the LUKS container, then the partition, in that exact order, with any mistake putting the primary OS at risk. The second drive held a Windows install I hadn't used in months and that had no EFI partition of its own, so I wiped it and gave Meridian a 100 GB partition, leaving the rest free.

### 3.3 Unencrypted root, no initramfs

Keeping the root unencrypted means Fedora's GRUB can read the Meridian kernel directly, and the kernel needs neither LUKS support nor an initramfs. The consequence is that every driver needed to reach the root filesystem (NVMe, ext4) must be compiled **into** the kernel, not as a module.

### 3.4 Boot through Fedora's GRUB

Running `grub-install` from LFS would overwrite Fedora's bootloader on the shared EFI partition. Instead, Meridian is a custom menu entry in Fedora's GRUB configuration. LFS's own GRUB was still built (64-bit UEFI target) so that Meridian could be made independently bootable later, for example in a VM image.

### 3.5 systemd edition

Chose the systemd version of the book to match Fedora's init system and tooling.

### 3.6 UUIDs and PARTUUIDs everywhere

NVMe device names (`nvme0`, `nvme1`) are not guaranteed to be stable across boots. All references use stable identifiers:

| Identifier | Value | Used for |
|---|---|---|
| Filesystem UUID | `efddce50-298d-479a-a4c2-65eba5023ffc` | fstab, GRUB `search` |
| Partition UUID | `d74238bb-83c9-4823-825f-2a1f676ab9bc` | kernel `root=` |

`root=UUID=` (filesystem UUID) only works with an initramfs, so the kernel command line uses `root=PARTUUID=`.

### 3.7 Build from Fedora's chroot, test natively

Most BLFS work was done from Fedora inside the chroot: Fedora provides a browser for reading the book, copy and paste, and working networking. Meridian is then rebooted to test anything that needs the running system (services, kernel changes, Wi-Fi). Once SSH was working, native builds became practical from a phone over SSH.

### 3.8 Selective test suites

Ran test suites the book marks as critical (GMP, Binutils, GCC, Glibc) and skipped or abandoned optional suites that were slow, hung, or impossible in the chroot (Elfutils/Libelf, Vim, LLVM).

### 3.9 Wired-first, then Wi-Fi from BLFS

Base LFS only supports wired networking. The laptop's Wi-Fi was added in BLFS with a rebuilt kernel, copied firmware, and wpa_supplicant.

### 3.10 Security as a theme

Each BLFS addition was chosen and configured with hardening in mind: a regular user with sudo instead of daily root, a single system certificate store, YESCRYPT password hashing, key-only SSH with root login disabled, a default-deny firewall covering IPv4 **and** IPv6, kernel network hardening via `/proc/sys`, and configuration change tracking in Git.

---

# Part I: LFS — Building the Base System

## Chapter 2: Host preparation and partitioning

### Host requirements check

The book's `version-check.sh` failed three checks on a stock Fedora install:

```
ERROR: Cannot find g++ (GCC (C++))
ERROR: Cannot find texi2any (Texinfo)
Aliases:
OK: awk  is GNU
ERROR: yacc is NOT Bison
OK: sh   is Bash
Compiler check:
version-check.sh: line 76: g++: command not found
ERROR: g++ does NOT work
```

Fixed by installing the missing packages and adding a `yacc` wrapper (see [Problem 1](#problem-1-fedora-host-missing-tools-and-yacc-not-being-bison)). Second run:

```
OK: GCC (C++) 16.2.1 >= 5.4
OK: Texinfo   7.2    >= 5.0
OK: yacc is Bison
OK: g++ works
OK: nproc reports 32 logical cores are available
```

### Partitioning the second NVMe

```bash
sudo wipefs -a /dev/nvme1n1
sudo parted /dev/nvme1n1 -- mklabel gpt
sudo parted /dev/nvme1n1 -- mkpart lfs ext4 1MiB 100GiB
sudo mkfs.ext4 -L lfs /dev/nvme1n1p1
```

```
Creating filesystem with 26214144 4k blocks and 6553600 inodes
Filesystem UUID: efddce50-298d-479a-a4c2-65eba5023ffc
```

```
$ sudo blkid /dev/nvme1n1p1
/dev/nvme1n1p1: LABEL="lfs" UUID="efddce50-298d-479a-a4c2-65eba5023ffc" BLOCK_SIZE="4096"
TYPE="ext4" PARTLABEL="lfs" PARTUUID="d74238bb-83c9-4823-825f-2a1f676ab9bc"
```

### Mounting

```bash
export LFS=/mnt/lfs
sudo mkdir -pv $LFS
sudo mount -v -t ext4 /dev/nvme1n1p1 $LFS
```

This produced an SELinux warning about the unlabeled filesystem, fixed with `restorecon` (see [Problem 3](#problem-3-selinux-label-warning-on-mount)). Persistent mount added to Fedora's `/etc/fstab`:

```
UUID=efddce50-298d-479a-a4c2-65eba5023ffc  /mnt/lfs  ext4  defaults  1 2
```

### Fedora-specific adaptation: no root account

Fedora locks the root password by default. Throughout the build:

- "As root" became `sudo` or a `sudo -i` shell
- `su - lfs` became `sudo su - lfs`
- `$LFS` had to be exported again in every new root shell, and was later added to `/root/.bash_profile`

---

## Chapter 3: Source packages

```bash
cd $LFS/sources
wget https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/md5sums
wget https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/wget-list
wget --input-file=wget-list --continue --directory-prefix=$LFS/sources
md5sum -c md5sums
sudo chown root:root $LFS/sources/*
```

```
[Files: 98  Bytes: 628.29M [37.42MB/s] Redirects: ]
acl-2.4.0.tar.xz: OK
...
tar-1.35-acl_fix-1.patch: OK
```

All 94 checksummed packages and patches verified. (The first attempt hit a 404; see [Problem 4](#problem-4-wget-list-filename-404).)

---

## Chapter 4: Build environment

- Created the minimal `$LFS` directory layout (`etc`, `var`, `usr/{bin,lib,sbin}`, `lib64`, `tools`, plus `bin`, `lib`, `sbin` as symlinks into `usr`)
- Created the unprivileged `lfs` build user on the host
- Set `MAKEFLAGS=-j$(nproc)` (32 jobs) in the `lfs` user's `.bashrc`
- `/etc/bash.bashrc` check: Fedora uses `/etc/bashrc` instead, so nothing needed moving

The directory layout step **silently failed** the first time. It was only discovered three sections later; see [Problem 5](#problem-5-missing-lfs-directory-layout--permission-denied).

---

## Chapter 5: Cross-toolchain

| Package | Notes |
|---|---|
| Binutils Pass 1 | Timed for the SBU baseline (60 s) |
| GCC Pass 1 | mpfr/gmp/mpc unpacked inside the GCC tree; `lib64` → `lib` sed verified with `diff`; `limits.h` step completed |
| Linux API Headers | Exposed the missing directory layout |
| Glibc | Sanity check passed |
| Libstdc++ | Built from a fresh GCC extract |

Binutils verification:

```
$ $LFS/tools/bin/x86_64-lfs-linux-gnu-ld --version | head -1
GNU ld (GNU Binutils) 2.47.20260726
$ $LFS/tools/bin/x86_64-lfs-linux-gnu-as --version | head -1
GNU assembler (GNU Binutils) 2.47.20260726
```

Glibc sanity check, the most important test in this chapter:

```bash
echo 'int main(){}' | $LFS_TGT-gcc -x c -
readelf -l a.out | grep ': /lib'
```

```
[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
```

---

## Chapter 6: Temporary tools

M4, Ncurses, Bash, Coreutils, and the rest of the temporary tools through GCC Pass 2, cross-compiled and installed with `DESTDIR=$LFS`. The key difference from Chapter 5: `--prefix=/usr` with `DESTDIR=$LFS`, rather than installing into `$LFS/tools`. Dropping `DESTDIR` would make `make install` target the host's real `/usr` (blocked as the `lfs` user, which is the safety net).

Notes:

- **Ncurses** runs its main configure from the source root, not the `build` directory used for `tic`
- **Bash** needs the `ln -sv bash $LFS/bin/sh` symlink after install
- **File** needs `rm -v $LFS/usr/lib/libmagic.la` after install

---

## Chapter 7: Chroot and backup

1. Changed ownership of everything under `$LFS` from `lfs` to `root`
2. Mounted the virtual kernel filesystems (`/dev`, `/dev/pts`, `/proc`, `/sys`, `/run`)
3. Entered the chroot and built Gettext, Bison, Perl, Python, Texinfo, and Util-linux
4. Cleaned up per 7.15.1, then made a backup

Backup with multithreaded xz instead of the book's single-threaded command:

```bash
cd $LFS
tar -I 'xz -T0' -cpf $HOME/lfs-temp-tools-13.1-systemd.tar.xz .
```

Saved to `/root/` and copied to `/home/ferguson/`.

---

## Chapter 8: The final system

About 80 packages compiled inside the chroot. Notable steps and choices:

| Package | Decision / note |
|---|---|
| Glibc locales | The book's test-coverage set plus `en_CA.UTF-8` |
| Timezone | `America/Halifax` |
| GMP | Critical test suite; ≥199 passing tests required before installing |
| Acl | 1 failure out of 16; the book documents `cp.test` as an expected failure at this stage |
| Pkgconf | Unpacks Meson inside its own tree to break a circular dependency |
| Python | OpenSSL 4 compatibility patch; `/etc/pip.conf` to suppress root-user and version-check warnings |
| Groff | `PAGE=letter` (Canada uses US Letter) |
| Shadow | YESCRYPT hashing, `/var/mail`, `/bin` and `/sbin` removed from `login.defs` PATH |
| Libelf | Library only, test suite skipped |
| Sqlite | Docs unpacked inside `sqlite-autoconf-3530400` |
| GRUB | Built for 64-bit UEFI only; 32-bit UEFI skipped |
| Vim | Test suite hung; killed from the host (see [Problem 9](#problem-9-vim-test-suite-hung)) |

A dirty-source-tree failure in M4 led to clearing about 40 leftover package directories (see [Problem 7](#problem-7-dirty-source-trees-m4-build-failure)).

---

## Chapter 9: System configuration

### Network

`/etc/systemd/network/10-eth-dhcp.network`, using a wildcard so the interface name doesn't matter:

```ini
[Match]
Name=en*

[Network]
DHCP=ipv4

[DHCPv4]
UseDomains=true
```

```bash
systemctl disable systemd-networkd-wait-online
```

Disabled because on a laptop that's often unplugged, it stalls boot about 2 minutes waiting for a network that never appears.

### DNS

systemd-resolved (the default). Unbound is used on the host but not available in base LFS; switching later means disabling resolved and pointing `/etc/resolv.conf` at `127.0.0.1`.

### Hosts

DHCP, so no static IP line. `localhost` and the hostname are handled by the `nss-myhostname` module.

### Console

Initially `FONT=Lat2-Terminus16` with the default US keymap (matching Fedora's `KEYMAP="us"`). Later changed for readability; see [Personalization](#personalization-meridian-identity-console-prompt).

### Locale

Verified before writing any config:

```
$ LC_ALL=en_CA.UTF-8 locale language
Canadian English
$ LC_ALL=en_CA.UTF-8 locale charmap
UTF-8
$ LC_ALL=en_CA.UTF-8 locale int_curr_symbol
CAD
$ LC_ALL=en_CA.UTF-8 locale int_prefix
1
```

`/etc/locale.conf`: `LANG=en_CA.UTF-8`. The Linux console falls back to `C.UTF-8`, since it can't render every character.

### Clock

No `/etc/adjtime`, so Meridian assumes the hardware clock is UTC. Fedora was found to be using local time, a leftover from the old Windows install; see [Problem 10](#problem-10-hardware-clock-set-to-local-time).

---

## Chapter 10: Making it bootable

### fstab

```
# file system                               mount-point  type  options   dump  fsck
UUID=efddce50-298d-479a-a4c2-65eba5023ffc   /            ext4  defaults  1     1
```

No swap partition and no EFI partition entry. Meridian never needs to mount Fedora's boot partition.

### Kernel 7.1.8

Started from `make defconfig` and applied the book's required options with `scripts/config` instead of navigating `menuconfig` option by option:

```bash
scripts/config \
  -d WERROR \
  -e PSI -d PSI_DEFAULT_DISABLED -d IKHEADERS \
  -e CGROUPS -e MEMCG -e CGROUP_SCHED -d RT_GROUP_SCHED -d EXPERT \
  -e RELOCATABLE -e RANDOMIZE_BASE \
  -e STACKPROTECTOR -e STACKPROTECTOR_STRONG \
  -e NET -e INET -e IPV6 \
  -d UEVENT_HELPER -e DEVTMPFS -e DEVTMPFS_MOUNT \
  -d FW_LOADER_USER_HELPER -e DMIID -e SYSFB_SIMPLEFB \
  -e TTY -d LEGACY_TIOCSTI \
  -e DRM -e DRM_PANIC --set-str DRM_PANIC_SCREEN kmsg \
  -e DRM_FBDEV_EMULATION -e DRM_SIMPLEDRM -e FRAMEBUFFER_CONSOLE \
  -e INOTIFY_USER -e TMPFS -e TMPFS_POSIX_ACL \
  -e PCI -e PCI_MSI -e IOMMU_SUPPORT -e IRQ_REMAP -e X86_X2APIC \
  -e BLK_DEV_NVME \
  -e EFI -e EFI_STUB -e EFI_PARTITION \
  -e VFAT_FS -e EFIVAR_FS -e NLS_CODEPAGE_437 -e NLS_ISO8859_1
make olddefconfig
```

Boot-critical options verified before compiling:

```bash
grep -E 'CONFIG_(BLK_DEV_NVME|EXT4_FS|EFI_STUB|DEVTMPFS_MOUNT)=' .config
```

All `=y`. `BLK_DEV_NVME=y` matters most: as a module, the kernel couldn't reach the NVMe root without an initramfs.

Installed:

```bash
make && make modules_install
cp -iv arch/x86/boot/bzImage /boot/vmlinuz-7.1.8-lfs-13.1-systemd
cp -iv System.map /boot/System.map-7.1.8
cp -iv .config /boot/config-7.1.8
```

The source tree was moved to `/usr/src/linux-7.1.8` (root-owned) and kept for incremental rebuilds. It's been rebuilt several times since: Wi-Fi, i915 as a module, and netfilter.

### GRUB entry on Fedora

`/etc/grub.d/40_custom` on Fedora:

```
menuentry "LFS 13.1-systemd" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root efddce50-298d-479a-a4c2-65eba5023ffc
    linux /boot/vmlinuz-7.1.8-lfs-13.1-systemd root=PARTUUID=d74238bb-83c9-4823-825f-2a1f676ab9bc ro quiet loglevel=3
}
```

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo grub2-editenv - unset menu_auto_hide   # Fedora hides the menu by default
```

Secure Boot must be off, since Fedora's shim and GRUB refuse unsigned kernels (check with `mokutil --sb-state`). `quiet loglevel=3` was added after first boot (see [Personalization](#personalization-meridian-identity-console-prompt)).

---

## Chapter 11: First boot

**Booted successfully on the first attempt.** Unmounting before reboot hit `target is busy`, caused by a Fedora terminal whose working directory was inside `/mnt/lfs` and by KDE auto-mounting the partition at `/run/media/ferguson/lfs`. With the virtual filesystems already unmounted, a normal reboot was safe.

---

# Part II: BLFS — Making It Usable

Base LFS at first boot had: a root account, wired DHCP, and a text console. Everything below was added from BLFS.

## Personalization: Meridian identity, console, prompt

### Name and hostname

The distro was named **Meridian** in `/etc/os-release` (`NAME=` and `PRETTY_NAME=`), which tools like fastfetch read, and the hostname was set to match:

```bash
sudo hostnamectl set-hostname meridian
```

The login banner now reads:

```
Meridian
Kernel 7.1.8 on an x86_64 (tty1)

Meridian login:
```

### Console font

`Lat2-Terminus16` was too small on the laptop's high-resolution screen.

- `setfont -d Lat2-Terminus16` (doubled) worked live but can't be set in `vconsole.conf`
- Settled on `LatGrkCyr-12x22`, which ships with LFS and is one of the fonts the book recommends for full character coverage
- Made permanent in `/etc/vconsole.conf` (`FONT=LatGrkCyr-12x22`) and applied with `systemctl restart systemd-vconsole-setup`
- Option for later: Terminus at 24 or 28 pixels (`ter-v24n`, `ter-v28n`) copied from Fedora's `terminus-fonts-console` package, since Kbd has nothing between 22 and 32 pixels

### Quiet boot

After i915 became a module, driver messages printed on top of the login prompt (`Initialized i915 1.6.0`, `fbcon: i915drmfb (fb0) is primary device`, Wi-Fi association messages). Fixed by adding `quiet loglevel=3` to the kernel command line in Fedora's `40_custom`. Real errors still show, and the full log remains available via `journalctl -b` and `dmesg`.

### Shell prompt

BLFS's `/etc/bashrc` sets a coloured prompt: green for users, red for root. It was modified to include the hostname with `\u@\h`.

### Chroot indicator in the prompt

Once BLFS's `/etc/bashrc` was installed, it overrode the `(lfs chroot)` prompt set by the chroot command. A root shell in the chroot looked identical to a native Meridian root shell (`root [ / ]#`), which made it easy to lose track of where a command was running. Fixed in `/root/.bashrc` by comparing the current root directory with the real system root:

```bash
# Show (chroot) in the prompt when inside a chroot
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/. 2>/dev/null)" ]; then
  PS1="(chroot) $PS1"
fi
```

| Prompt | Where you are |
|---|---|
| `ferguson@fedora` | Fedora host |
| `(chroot) root [ ... ]#` | Meridian via chroot from Fedora |
| `ferguson [ ... ]$` / `root [ ... ]#` | Meridian booted natively |

### Login banner

`/etc/issue` is shown on the local console above the `login:` prompt (not over SSH). It now shows a "Meridian" banner in block characters, followed by:

```
Kernel \r on \m (\l)
```

`\r`, `\m`, and `\l` are filled in by agetty with the kernel release, architecture, and tty. Backslashes in the art itself would have to be doubled (`\\`), since agetty treats them as escape codes, which is why the art uses none.

**Known issue:** `LatGrkCyr-12x22` lacks the Unicode block-element glyphs (`█ ▀ ▄`), so they render as substitutes. Terminus (`ter-v24n`/`ter-v28n`) has full block-element coverage and is the planned fix.

---

## Users, sudo, and shell startup files

### Regular user

Everything up to this point had been done as root.

```bash
useradd -m -G wheel ferguson
passwd ferguson
```

### sudo

Built from BLFS without Linux-PAM (it authenticates directly against `/etc/shadow`). Wheel group access:

```bash
cat > /etc/sudoers.d/00-wheel << "EOF"
%wheel ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/00-wheel
```

Verified:

```
-su-5.3$ sudo whoami

We trust you have received the usual lecture from the local System
Administrator. It usually boils down to these three things:
    #1) Respect the privacy of others.
    #2) Think before you type.
    #3) With great power comes great responsibility.

[sudo] password for ferguson:
root
```

### Bash startup files

The `-su-5.3$` prompt showed the user had no startup files. Built BLFS's system-wide set:

- `/etc/profile`, with helper functions `pathappend`, `pathprepend`, and `pathremove`
- `/etc/profile.d/extrapaths.sh`, `readline.sh`, `umask.sh`, `i18n.sh`
- `/etc/bashrc`, with the coloured prompt and `ls`/`grep` colour aliases
- `/etc/dircolors` (`dircolors -p > /etc/dircolors`)

Per-user files (`.bash_profile`, `.profile`, `.bashrc`, `.bash_logout`) were written to `/etc/skel` so future users get them automatically, then copied to `/root` and `/home/ferguson`.

One side effect: BLFS's `/etc/profile` runs `unset HISTFILE` for root, so root no longer keeps a history file. That's deliberate for security, but it means routine work is better done as `ferguson` with `sudo`.

**PATH fix:** `/usr/sbin` is only in root's PATH under the BLFS profile, so `ip` and `wpa_passphrase` returned `command not found` for `ferguson`. Fixed per-user:

```bash
echo 'pathappend /usr/sbin' >> ~/.bash_profile
```

### Default editor

GNU nano was the first package built natively on Meridian. Set as default editor so Ctrl+X Ctrl+E (edit the current command line) and `sudoedit` use it:

```bash
echo 'export EDITOR=nano' >> ~/.bash_profile
```

---

## Certificates and HTTPS

Base LFS can't verify HTTPS certificates. Built in dependency order:

1. **libtasn1** (Chapter 9, General Libraries)
2. **p11-kit** (Chapter 4, Security)
3. **make-ca** (Chapter 4, Security)

```bash
/usr/sbin/make-ca -g                  # generate the certificate store
systemctl enable update-pki.timer     # keep it updated weekly
```

Python's `pip` was pointed at the system certificate store instead of its bundled snapshot:

```bash
cat > /etc/profile.d/pythoncerts.sh << "EOF"
# Begin /etc/profile.d/pythoncerts.sh

export _PIP_STANDALONE_CERT=/etc/pki/tls/certs/ca-bundle.crt

# End /etc/profile.d/pythoncerts.sh
EOF
```

This means one certificate store under administrator control, rather than each tool shipping its own aging copy.

Skipped by choice: custom `make-ca.conf`, CAcert roots, and overriding Mozilla trust. Those were examples in the book, not requirements.

### wget

Built **wget** (Chapter 15) so Meridian can fetch its own source packages. End-to-end HTTPS test from the chroot:

```
(lfs chroot) root:/# wget -O /dev/null https://www.linuxfromscratch.org/
Resolving www.linuxfromscratch.org (www.linuxfromscratch.org)... 208.118.68.85
Connecting to www.linuxfromscratch.org (www.linuxfromscratch.org)|208.118.68.85|:443... connected.
HTTP request sent, awaiting response... 200 OK
```

DNS, TLS, certificate validation, and the download all working.

---

## Wi-Fi: firmware, kernel drivers, wpa_supplicant

### Identifying the hardware (on Fedora)

```
$ lspci -k | grep -A3 -i network
00:14.3 Network controller: Intel Corporation 700 Series Chipset Family CNVi Wi-Fi (rev 11)
        Subsystem: Intel Corporation Device 0094
        Kernel driver in use: iwlwifi
        Kernel modules: iwlwifi

$ lsmod | grep iwl
iwlmvm                872448  0
mac80211             2076672  1 iwlmvm
iwlwifi               589824  1 iwlmvm
cfg80211             1691648  3 iwlmvm,iwlwifi,mac80211
rfkill                 45056  8 iwlmvm,bluetooth,ideapad_laptop,cfg80211

$ sudo dmesg | grep -iE 'iwlwifi.*(firmware|pnvm|loaded)'
iwlwifi 0000:00:14.3: loaded firmware version 89.d2579d43.0 so-a0-gf-a0-89.ucode op_mode iwlmvm
```

Conclusions: an Intel AX211-class card, sub-driver `iwlmvm`, firmware family `so-a0-gf-a0`.

### Firmware

Fedora had eleven versions of the firmware file plus a `.pnvm` file, all xz-compressed:

```
iwlwifi-so-a0-gf-a0-72.ucode.xz ... iwlwifi-so-a0-gf-a0-89.ucode.xz
iwlwifi-so-a0-gf-a0.pnvm.xz
```

**Decision: copy all of them, not just version 89.** Meridian's kernel (7.1.8) is older than Fedora's (7.2.7) and might not support firmware API 89. `iwlwifi` tries the highest version it supports and works downward, so the full set guarantees a match. They total about 20 MB.

```bash
sudo mkdir -p /mnt/lfs/usr/lib/firmware
sudo cp -v /usr/lib/firmware/iwlwifi-so-a0-gf-a0* /mnt/lfs/usr/lib/firmware/
sudo unxz -v /mnt/lfs/usr/lib/firmware/iwlwifi-so-a0-gf-a0*.xz
```

Decompressed rather than enabling compressed firmware loading in the kernel.

### Kernel configuration

**The Wi-Fi drivers had to be modules (`=m`), the opposite of NVMe.** Built-in drivers initialize before the root filesystem is mounted, so a built-in `iwlwifi` couldn't read its firmware from `/usr/lib/firmware`. As modules, they load after root is available.

```bash
scripts/config -e WIRELESS -e WLAN -e WLAN_VENDOR_INTEL \
  -m CFG80211 -m MAC80211 -m RFKILL \
  -m IWLWIFI -m IWLMVM \
  -m IDEAPAD_LAPTOP
```

`IDEAPAD_LAPTOP` handles the Lenovo's Wi-Fi radio switch, without which the radio can stay soft-blocked.

Kernel crypto options for WPA were also enabled (`CRYPTO_USER_API_SKCIPHER`, `CRYPTO_USER_API_HASH`, `CRYPTO_HMAC`, `CRYPTO_CMAC`, `CRYPTO_SHA256`, `CRYPTO_AES`, `KEY_DH_OPERATIONS`, the X.509 and PKCS parsers, and others). These were originally aimed at iwd, but they're harmless and useful to have.

### Userspace: iwd → wpa_supplicant

**iwd** was the original plan but turned out **not to be in BLFS 13.1**. Switched to the book-supported route:

1. **libnl** (Chapter 9): the netlink library that lets programs talk to the kernel's `nl80211` wireless interface. Without it, wpa_supplicant falls back to the deprecated Wireless Extensions.
2. **wpa_supplicant** (Chapter 15): built from the book's `.config` with `CONFIG_DRIVER_NL80211=y` and `CONFIG_LIBNL32=y`, plus D-Bus support files and systemd units

NetworkManager was deliberately skipped: wpa_supplicant handles the WPA association, systemd-networkd handles DHCP, and fewer moving parts suits a hardened system.

DHCP for wireless (`/etc/systemd/network/20-wlan.network`):

```ini
[Match]
Name=wl*

[Network]
DHCP=ipv4
```

### First boot with Wi-Fi

```
iwlwifi 0000:00:14.3: Detected Intel(R) Wi-Fi 6E AX211 160MHz
iwlwifi 0000:00:14.3: loaded firmware version 89.d2579d43.0 so-a0-gf-a0-89.ucode op_mode iwlmvm
iwlwifi 0000:00:14.3 wlp0s20f3: renamed from wlan0
```

The driver loaded firmware 89 successfully, and the interface was named **`wlp0s20f3`**: **wl**an, **p**ci bus **0**, **s**lot **20** (`0x14`), **f**unction **3**, matching `lspci`'s `00:14.3`.

### Getting connected

This took several attempts; the full story is in [Problem 13](#problem-13-wi-fi-configuration-file-mix-ups). The working sequence:

```bash
/usr/sbin/wpa_passphrase "<SSID>" > /tmp/wpa.conf      # type the password at the blank prompt
cat /tmp/wpa.conf                                       # verify: only a network={} block
sudo install -m 600 /tmp/wpa.conf /etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf
rm /tmp/wpa.conf
sudo systemctl enable --now wpa_supplicant@wlp0s20f3
sudo systemctl restart systemd-networkd
```

Typing the password at the prompt rather than as an argument keeps it out of shell history, and `install -m 600` makes the file root-only, since it contains the network key.

Success:

```
wpa_supplicant[1704]: wlp0s20f3: WPA: Key negotiation completed with xx:xx:xx:xx:xx:xx
wpa_supplicant[1704]: wlp0s20f3: CTRL-EVENT-CONNECTED - Connection to xx:xx:xx:xx:xx:xx completed

2: wlp0s20f3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.0.12/24 metric 1024 brd 192.168.0.255 scope global dynamic wlp0s20f3
```

On later boots, Wi-Fi associates automatically:

```
wlp0s20f3: authenticate with xx:xx:xx:xx:xx:xx
wlp0s20f3: authenticated
wlp0s20f3: associate with xx:xx:xx:xx:xx:xx (try 1/3)
wlp0s20f3: RX AssocResp from xx:xx:xx:xx:xx:xx (capab=0x1131 status=0 aid=13)
wlp0s20f3: associated
```

At this point Meridian was **fully self-sufficient**: it boots on its own, connects over Wi-Fi, and downloads over verified HTTPS.

---

## Graphics and regulatory firmware

### The problem

The first Wi-Fi boot's `dmesg` also showed:

```
i915 0000:00:02.0: Direct firmware load for i915/adls_dmc_ver2_01.bin failed with error -2
i915 0000:00:02.0: [drm] Failed to load DMC firmware i915/adls_dmc_ver2_01.bin (-ENOENT). Disabling runtime power management.
i915 0000:00:02.0: [drm] *ERROR* GT0: GuC firmware i915/tgl_guc_70.bin: fetch failed -ENOENT
faux_driver regulatory: Direct firmware load for regulatory.db failed with error -2
```

`error -2` (`ENOENT`) means the file wasn't found.

- **DMC** is the display microcontroller firmware. Without it, the GPU's runtime power management is disabled, which costs battery life.
- **GuC** is the graphics scheduling microcontroller firmware.
- **regulatory.db** is the wireless regulatory database. Without it, Wi-Fi is limited to conservative worldwide defaults.

### The underlying issue

`i915` was **built into** the kernel (defconfig sets `DRM_I915=y`). Like Wi-Fi, a built-in driver starts before the root filesystem is mounted, so even with the files present it could never load them.

### Fix

Copied the files from Fedora:

```
$ ls /usr/lib/firmware/regulatory.db* /usr/lib/firmware/i915/{adls_dmc_ver2_01,tgl_guc_70}*
/usr/lib/firmware/i915/adls_dmc_ver2_01.bin.xz   /usr/lib/firmware/regulatory.db
/usr/lib/firmware/i915/tgl_guc_70.1.1.bin.xz     /usr/lib/firmware/regulatory.db.p7s
/usr/lib/firmware/i915/tgl_guc_70.bin.xz
```

```bash
sudo cp -v /usr/lib/firmware/regulatory.db* /mnt/lfs/usr/lib/firmware/
sudo mkdir -p /mnt/lfs/usr/lib/firmware/i915
sudo cp -v /usr/lib/firmware/i915/adls_dmc_ver2_01.bin.xz \
           /usr/lib/firmware/i915/tgl_guc_70.bin.xz \
           /mnt/lfs/usr/lib/firmware/i915/
sudo unxz -v /mnt/lfs/usr/lib/firmware/i915/*.xz
```

Rebuilt the kernel with i915 as a module:

```bash
scripts/config -m DRM_I915
make olddefconfig
```

### Result

```
i915 0000:00:02.0: [drm] Registered 4 planes with drm panic
[drm] Initialized i915 1.6.0 for 0000:00:02.0 on minor 1
fbcon: i915drmfb (fb0) is primary device
Console: switching to colour frame buffer device 320x100
i915 0000:00:02.0: [drm] fb0: i915drmfb frame buffer device
```

The boot sequence now goes: the EFI framebuffer via simpledrm, then i915 loading from disk with its firmware and taking over the display.

---

## First native build

**GNU nano**: downloaded, compiled, and installed entirely on Meridian, using Meridian's own toolchain. The first package not built from Fedora's chroot.

Native building by keyboard alone is slow, because long BLFS commands have to be typed by hand. That's what made SSH the next priority.

---

## OpenSSH

### Build

Dependencies: all optional ones skipped (GDB, Linux-PAM, Xorg, Kerberos, libedit, LibreSSL, OpenSC, libsectok, Net-tools, Sysstat). OpenSSH only strictly needs OpenSSL and zlib, both already in LFS.

Privilege separation user:

```
root [ /sources/openssh-10.5p1 ]# install -v -g sys -m700 -d /var/lib/sshd &&
groupadd -g 50 sshd &&
useradd -c 'sshd PrivSep' -d /var/lib/sshd -g sshd -s /bin/false -u 50 sshd
install: creating directory '/var/lib/sshd'
useradd warning: sshd's uid 50 outside of the UID_MIN 1000 and UID_MAX 60000 range.
```

The warning is expected: system accounts deliberately sit below UID 1000.

### systemd unit

The service unit isn't part of OpenSSH; it comes from **blfs-systemd-units**, a separate BLFS package:

```
root [ /sources/openssh-10.5p1 ]# make install-sshd
make: *** No rule to make target 'install-sshd'.  Stop.
```

(Wrong directory. It has to be run from inside the extracted blfs-systemd-units folder.) That package was kept in `/sources` permanently, since many BLFS services come from it.

### Configuration

```bash
ssh-keygen -A                                         # host keys
echo "PermitRootLogin no" >> /etc/ssh/sshd_config
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "KbdInteractiveAuthentication no" >> /etc/ssh/sshd_config
systemctl enable sshd
```

### Authorized keys

Existing keys were reused rather than generating new ones on each client. Fedora's `~/.ssh/authorized_keys` was copied into Meridian. It turned out to contain only the Termux (phone) key, so the laptop key (`toplap`) was added separately:

```
ssh-ed25519 AAAAC3...Lua EbAwzY termux
ssh-ed25519 AAAAC3...Rce A0c toplap
```

Getting this working uncovered an ownership problem; see [Problem 14](#problem-14-ssh-key-rejected-wrong-owner-on-ssh).

### Verification

From the journal, after fixing:

```
sshd[692]: Server listening on 0.0.0.0 port 22.
sshd[692]: Server listening on :: port 22.
sshd-session[739]: Failed password for root from 192.168.0.101 port 35464 ssh2
```

The root login attempt was refused, confirming `PermitRootLogin no`.

**Result:** working SSH from the phone (Termux), which made native BLFS builds practical: the book open on the phone, commands pasted straight into the session.

### Client tip: two operating systems, one IP address

Fedora and Meridian share the laptop and its IP address but have **different SSH host keys**. Connecting to the same IP after switching OS triggers `REMOTE HOST IDENTIFICATION HAS CHANGED`. That's SSH doing its job. The fix is a separate host alias per OS on each client:

```
Host meridian
    HostName 192.168.0.12
    User ferguson
    HostKeyAlias meridian
```

### Outbound SSH from Meridian

Meridian connecting **out** to other hosts on the LAN was refused with `Permission denied (publickey)`, since Meridian had no client key of its own yet. The fix is `ssh-keygen -t ed25519 -C "meridian"`, then adding the public key to those hosts via an already-trusted device.

The OpenSSH 10 client also warned:

```
** WARNING: connection is not using a post-quantum key exchange algorithm.
** This session may be vulnerable to "store now, decrypt later" attacks.
** The server may need to be upgraded. See https://openssh.com/pq.html
```

That points at the **remote** servers running older OpenSSH without post-quantum key exchange, not at Meridian. It's a hardening item for those hosts.

---

## The Rust toolchain and Git

### How Git led to Rust

Git's BLFS page lists **cURL** (needed for HTTPS clones and pushes) and **rustc** as recommended. Without rustc, the build failed when it reached Git's Rust component:

```
    CARGO target/release/libgitcore.a
/bin/sh: line 1: cargo: command not found
make: *** [Makefile:3021: target/release/libgitcore.a] Error 127
```

**Decision:** rather than disabling Rust in Git, build the full Rust toolchain now, since a desktop stack (Mesa, librsvg, Firefox) will require it later anyway.

### Build order

1. **cURL**: HTTPS for Git, and used by Rust's build
2. **libssh2**
3. **CMake**: LLVM's build system
4. **LLVM 22.1.8**, with `-D LLVM_LINK_LLVM_DYLIB=ON` so rustc links against the system LLVM instead of compiling its own bundled copy. One LLVM build serves both Rust and, later, Mesa.
5. **rustc 1.97.1**, using the system LLVM, libssh2, and SQLite (`LIBSSH2_SYS_USE_PKG_CONFIG=1`, `LIBSQLITE3_SYS_USE_PKG_CONFIG=1`)
6. **Git 2.55.0**, rebuilt from a clean extract so it finds `cargo`. The `git-manpages` tarball was included, which avoids needing asciidoc for `man git`.

### LLVM: out of memory

Partway through (job 3203 of 4477), the compiler was killed:

```
FAILED: tools/clang/lib/ASTMatchers/Dynamic/CMakeFiles/obj.clangDynamicASTMatchers.dir/Registry.cpp.o
...
g++: fatal error: Killed signal terminated program cc1plus
compilation terminated.
```

**Cause:** the kernel's out-of-memory killer. LLVM's C++ files can each need 1–2 GB of RAM while compiling, and 32 parallel jobs were competing with Fedora's browser tabs and Spotify for the same memory (the build ran in the chroot, on Fedora's kernel).

**Fix:** resumed with fewer parallel jobs. Ninja picks up where it stopped, so the ~3,200 completed objects weren't rebuilt:

```bash
cd /sources/llvm-project-22.1.8.src/llvm/build
ninja -j8
```

Rule of thumb: about one job per 2 GB of available RAM for heavy C++ builds. Memory was watched from a second terminal with `watch -n 2 free -h`.

### LLVM: test suite not possible in the chroot

```
root [ /sources/llvm-project-22.1.8.src/llvm/build ]# systemctl --user start dbus &&
systemd-run --user --pty -d -G -p LimitCORE=0 ninja check-all
Running in chroot, ignoring command 'start'
Failed to connect to user scope bus via local transport: No such file or directory
```

The test procedure needs a running user session with D-Bus, which doesn't exist in a chroot. The tests were skipped (optional, and very long), and LLVM was installed directly.

### rustc: no DNS in the chroot

Rust's build first downloads a bootstrap compiler:

```
downloading https://static.rust-lang.org/dist/2026-05-28/rust-std-1.96.0-x86_64-unknown-linux-gnu.tar.xz
curl: (6) Could not resolve host: static.rust-lang.org
...
spurious failure, trying again
```

**Cause:** after Meridian's first boot, systemd-resolved had replaced `/etc/resolv.conf` with a symlink into `/run/systemd/resolve/`. In the chroot, `/run` is a fresh empty tmpfs, so the symlink pointed at nothing.

**Fix**, from Fedora, after mounting `/run`:

```bash
mkdir -p $LFS/run/systemd/resolve
cp /etc/resolv.conf $LFS/run/systemd/resolve/stub-resolv.conf
```

That copies Fedora's DNS configuration to where Meridian's symlink expects it. Because it lives in the temporary `/run` mount, it disappears when the chroot session ends, and Meridian's own configuration is never modified. Both lines were added permanently to the chroot entry script ([Appendix A](#appendix-a-command-reference)).

---

## Configuration tracking with Git

`/etc` was turned into a **local** Git repository:

```bash
git config --global user.name "Curtis Ferguson"
git config --global user.email "curtiscyber@outlook.com"
cd /etc
git init
chmod 700 /etc/.git
git add -A
git commit -m "Meridian baseline"
```

### Why `chmod 700 /etc/.git` matters

Git stores a full copy of every tracked file inside `.git`, including `/etc/shadow`. By default `.git` is world-readable, which would let any user on the system read the password hashes **from the repository** even though `/etc/shadow` itself is locked down. Restricting `.git` to root closes that hole.

### What it provides

- **History:** `git log` shows every configuration change with a message
- **Rollback:** `git diff` shows what changed; `git checkout <file>` restores it
- **Change detection:** `git status` shows modified files, including any changed by something other than me. A simple form of integrity monitoring.

### Limitations

Git doesn't record ownership or most permission bits, so the repo is a record and rollback tool, not a backup. `etckeeper` would handle permission metadata.

### Local only

This repository is **never pushed anywhere**. It contains password hashes, SSH host private keys, and the Wi-Fi PSK. A separate, curated public repository is planned; see [Appendix B](#appendix-b-what-not-to-publish).

---

## Firewall

### Choosing the tool

**nftables** was the original plan but **isn't in BLFS 13.1**. BLFS provides **iptables-1.8.13** plus a "Setting Up a Network Firewall" page with example scripts and a systemd unit. Modern iptables runs on the same kernel netfilter framework, so this isn't outdated technology, just a different front end with book-tested instructions.

### Choosing a ruleset

The BLFS page offers several setups:

| Example | Fit |
|---|---|
| Personal Firewall | Right base, but blocks **all** inbound connections, **including SSH**, and has no IPv6 rules |
| Masquerading Router | Wrong for a laptop: enables IP forwarding and NAT, and references a `WAN1` interface that doesn't exist |
| BusyBox (router with services) | Wrong scenario; a reference for rule syntax only |

The final script merges the Personal Firewall's kernel hardening with explicit allow rules and IPv6 coverage.

### `/etc/systemd/scripts/iptables`

```sh
#!/bin/sh
# Begin /etc/systemd/scripts/iptables
# Meridian: BLFS personal firewall + LAN SSH + IPv6

LAN=192.168.0.0/24

modprobe nf_conntrack 2>/dev/null
modprobe xt_LOG 2>/dev/null

# Kernel network hardening (from BLFS)
echo 1 > /proc/sys/net/ipv4/icmp_echo_ignore_broadcasts
echo 0 > /proc/sys/net/ipv4/conf/all/accept_source_route
echo 0 > /proc/sys/net/ipv4/conf/default/accept_source_route
echo 1 > /proc/sys/net/ipv4/tcp_syncookies
echo 0 > /proc/sys/net/ipv4/conf/all/accept_redirects
echo 0 > /proc/sys/net/ipv4/conf/default/accept_redirects
echo 0 > /proc/sys/net/ipv4/conf/all/send_redirects
echo 0 > /proc/sys/net/ipv4/conf/default/send_redirects
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/default/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/all/log_martians
echo 1 > /proc/sys/net/ipv4/conf/default/log_martians
echo 0 > /proc/sys/net/ipv4/ip_forward

# ---- IPv4 ----
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT
iptables -F
iptables -X
iptables -Z

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p udp --sport 67 --dport 68 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s $LAN -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -s $LAN -j ACCEPT
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "FIREWALL:INPUT "

# ---- IPv6 ----
ip6tables -P INPUT   DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT  ACCEPT
ip6tables -F
ip6tables -X
ip6tables -Z

ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate INVALID -j DROP
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -p ipv6-icmp -j ACCEPT

# End /etc/systemd/scripts/iptables
```

### Rule-by-rule rationale

| Rule | Why |
|---|---|
| `INPUT` policy `DROP` | Default deny: anything not explicitly allowed is dropped |
| `FORWARD` policy `DROP` | Meridian is not a router |
| `OUTPUT` policy `ACCEPT` | Outbound traffic unrestricted; restricting it is a later hardening step |
| `-i lo ACCEPT` | Local services talking to each other must work |
| `INVALID DROP` | Drops malformed packets and stray packets from some scan types |
| `ESTABLISHED,RELATED ACCEPT` | Replies to connections Meridian started |
| UDP 67→68 | DHCP lease renewals, so the laptop keeps its address |
| TCP 22 from LAN, `NEW` | SSH only from `192.168.0.0/24` |
| ICMP echo-request from LAN | Ping from the local network only |
| Rate-limited `LOG` | Records dropped packets in the kernel log without flooding it |
| **IPv6 rules** | Without them, IPv6 traffic bypasses the IPv4 firewall entirely |
| ICMPv6 `ACCEPT` | IPv6 depends on ICMPv6 for neighbour discovery; blocking it breaks IPv6 |
| `ip_forward = 0` | Explicitly no routing |
| `rp_filter`, `accept_redirects`, `accept_source_route`, `tcp_syncookies`, `log_martians` | Reject spoofed and source-routed packets, ignore ICMP redirects, resist SYN floods, log impossible addresses |

### Installation

```bash
chmod 700 /etc/systemd/scripts/iptables
cd /sources/blfs-systemd-units-*/
make install-iptables
systemctl enable iptables
```

**The script must not be executed inside the chroot.** The chroot isolates the filesystem but shares the host's running kernel, so running it there would apply the rules and `/proc/sys` settings to **Fedora's live system**. Writing the file and enabling the service only touch files, and the script runs for real when Meridian boots. (Fedora was checked with `sudo iptables -L -n` and was clean; Fedora's own firewall, firewalld, uses separate nftables rules.)

### First boot: the firewall didn't load

```
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/7.1.8
iptables v1.8.13 (legacy): can't initialize iptables table 'filter': Table does not exist (do you need to insmod?)
Perhaps iptables or your kernel needs to be upgraded.
modprobe: FATAL: Module ip6_tables not found in directory /lib/modules/7.1.8
```

The defconfig kernel had no netfilter table support. Full details in [Problem 17](#problem-17-firewall-kernel-missing-netfilter-tables). The key discovery: newer kernels gate the legacy iptables tables behind `CONFIG_NETFILTER_XTABLES_LEGACY`.

### Verified working

```
$ systemctl status iptables
● iptables.service - Load Iptables Rules
     Loaded: loaded (/usr/lib/systemd/system/iptables.service; enabled; preset: enabled)
     Active: active (exited) since Sat 2026-10-10 22:27:20 ADT
    Process: 490 ExecStart=/etc/systemd/scripts/iptables (code=exited, status=0/SUCCESS)
```

```
$ sudo iptables -L -n -v
Chain INPUT (policy DROP 3 packets, 162 bytes)
 pkts bytes target  prot opt in  out  source           destination
    0     0 ACCEPT  all  --  lo  *    0.0.0.0/0        0.0.0.0/0
    0     0 DROP    all  --  *   *    0.0.0.0/0        0.0.0.0/0    ctstate INVALID
    4   354 ACCEPT  all  --  *   *    0.0.0.0/0        0.0.0.0/0    ctstate RELATED,ESTABLISHED
    0     0 ACCEPT  udp  --  *   *    0.0.0.0/0        0.0.0.0/0    udp spt:67 dpt:68
    1   256 ACCEPT  tcp  --  *   *    192.168.0.0/24   0.0.0.0/0    tcp dpt:22 ctstate NEW
    0     0 ACCEPT  icmp --  *   *    192.168.0.0/24   0.0.0.0/0    icmptype 8
    3   162 LOG     all  --  *   *    0.0.0.0/0        0.0.0.0/0    limit: avg 5/min burst 5 LOG flags 0 level 4 prefix "FIREWALL:INPUT "

Chain FORWARD (policy DROP 0 packets, 0 bytes)
Chain OUTPUT (policy ACCEPT 10 packets, 580 bytes)
```

```
$ sudo ip6tables -L -n -v
Chain INPUT (policy DROP 3 packets, 222 bytes)
    0     0 ACCEPT  all       lo  *   ::/0  ::/0
    0     0 DROP    all       *   *   ::/0  ::/0   ctstate INVALID
    0     0 ACCEPT  all       *   *   ::/0  ::/0   ctstate RELATED,ESTABLISHED
    0     0 ACCEPT  ipv6-icmp *   *   ::/0  ::/0
```

Reading the counters:

- **The SSH rule matched 1 packet** from the LAN, so the Termux connection after boot went through
- **The LOG rule caught 3 packets** that were then dropped by policy (viewable with `sudo journalctl -k | grep FIREWALL`)
- **IPv6 INPUT dropped 3 packets** by policy

### Cleanup

The service log also showed:

```
iptables v1.8.13 (legacy): can't initialize iptables table 'nat': Table does not exist
```

That came from an `iptables -t nat -F` line carried over from the BLFS example. Meridian has no NAT, so the line was removed:

```bash
sudo sed -i '/-t nat -F/d' /etc/systemd/scripts/iptables
cd /etc && sudo git add -A && sudo git commit -m "Firewall live; remove NAT flush"
```

---

## Backups and recovery

### Full system backup

The only earlier backup dated from Chapter 7, before the final system existed. A full backup was taken from Fedora with Meridian not in use and the virtual filesystems unmounted (otherwise tar would descend into Fedora's live `/dev`, `/proc`, `/sys`, and `/run`):

```bash
sudo -i
export LFS=/mnt/lfs
umount -v ${LFS:?}/dev/shm ${LFS:?}/dev/pts
umount -v ${LFS:?}/{sys,proc,run,dev}
findmnt -R ${LFS:?}          # should show only /mnt/lfs itself
cd ${LFS:?}
tar -I 'xz -T0' -cpf /root/meridian-$(date +%F).tar.xz --exclude=./sources .
```

`--exclude=./sources` skips the source tarballs, which can be re-downloaded. Plan: repeat before risky steps, especially the Linux-PAM rebuild of Shadow, sudo, and systemd, which can break logins.

### Fallback kernel

Before kernel rebuilds, the working kernel is preserved:

```bash
cp -v /boot/vmlinuz-7.1.8-lfs-13.1-systemd /boot/vmlinuz-7.1.8-lfs-13.1-systemd.good
```

With a second GRUB entry on Fedora:

```
menuentry "Meridian (fallback kernel)" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root efddce50-298d-479a-a4c2-65eba5023ffc
    linux /boot/vmlinuz-7.1.8-lfs-13.1-systemd.good root=PARTUUID=d74238bb-83c9-4823-825f-2a1f676ab9bc ro quiet loglevel=3
}
```

### Recovery layers

| Failure | Recovery |
|---|---|
| Bad config change | `/etc` Git repo: `git diff`, `git checkout <file>` |
| New kernel won't boot | Fallback kernel entry in GRUB |
| Meridian won't boot at all | Boot Fedora, chroot in, repair |
| Catastrophic damage | Restore the latest `meridian-*.tar.xz` |

### Backup history

| Archive | Size | Taken before |
|---|---|---|
| `lfs-temp-tools-13.1-systemd.tar.xz` | n/a | Chapter 8 (temporary tools only) |
| `meridian-2026-10-10.tar.xz` | 1.4 GB | Firewall and later BLFS work |
| `meridian-2026-10-11.tar.xz` | 1.5 GB | Linux-PAM |

### Chroot script hardening

The chroot entry script was converted to use `${LFS:?}` everywhere in one pass:

```bash
sed -i 's/\$LFS/${LFS:?}/g' /root/lfs-chroot.sh
grep -c 'LFS:?' /root/lfs-chroot.sh
```

Its mount line is guarded so it doesn't stack a second mount on `/mnt/lfs` (one stacked mount was found during a backup, from an earlier manual mount):

```bash
findmnt /mnt/lfs || mount -v /dev/disk/by-uuid/efddce50-298d-479a-a4c2-65eba5023ffc ${LFS:?}
```

---

## Expanding the root partition

The original 100 GB partition left about 377 GB of the 512 GB drive unused. Because the partition started at the beginning of the drive with free space directly after it, it could be grown in place: extend the partition's end, then grow the filesystem. The start doesn't move, so the data stays put, and the filesystem UUID and PARTUUID don't change, so fstab and GRUB need no edits.

### The near miss

The first `lsblk` before resizing showed this:

```
NAME                                          SIZE  TYPE  MOUNTPOINTS
nvme1n1                                       953.9G disk
├─nvme1n1p1                                     600M part /boot/efi
├─nvme1n1p2                                       2G part /boot
└─nvme1n1p3                                   951.3G part
  └─luks-f21c6cdb-...                         951.3G crypt /home
                                                           /
```

**The NVMe device names had swapped since the partition was created.** `nvme1n1` was now the *Fedora* disk. The planned command, `parted /dev/nvme1n1 -- resizepart 1 100%`, would have targeted Fedora's EFI System Partition.

It was caught by checking `lsblk` before running anything. Identifying the disk by label instead:

```
$ lsblk -o NAME,SIZE,LABEL,MOUNTPOINTS
nvme1n1                                       953.9G
├─nvme1n1p1                                     600M               /boot/efi
├─nvme1n1p2                                       2G               /boot
└─nvme1n1p3                                   951.3G
  └─luks-...                                  951.3G fedora_fedora /home
nvme0n1                                       476.9G
└─nvme0n1p1                                     100G lfs
```

This was the real-world payoff of the decision to use UUIDs and PARTUUIDs everywhere ([3.6](#36-uuids-and-partuuids-everywhere)): fstab and GRUB kept working across the swap, and only a hand-typed device name was at risk.

### The resize

From Fedora, with the partition unmounted everywhere (including KDE's auto-mount at `/run/media/ferguson/lfs`):

```bash
parted /dev/nvme0n1 -- resizepart 1 100%
e2fsck -f /dev/nvme0n1p1
resize2fs /dev/nvme0n1p1
```

```
Information: You may need to update /etc/fstab.

e2fsck 1.47.3 (8-Jul-2025)
Pass 1: Checking inodes, blocks, and sizes
Pass 2: Checking directory structure
Pass 3: Checking directory connectivity
Pass 4: Checking reference counts
Pass 5: Checking group summary information
lfs: 1232325/6553600 files (0.1% non-contiguous), 10049681/26214144 blocks
resize2fs 1.47.3 (8-Jul-2025)
Resizing the filesystem on /dev/nvme0n1p1 to 125026641 (4k) blocks.
The filesystem on /dev/nvme0n1p1 is now 125026641 (4k) blocks long.

NAME          SIZE LABEL
nvme0n1     476.9G
└─nvme0n1p1 476.9G lfs
```

- `e2fsck -f` is required before `resize2fs` on an unmounted filesystem; it came back clean
- The `/etc/fstab` notice is a generic parted reminder; nothing needed changing because the identifiers are unchanged
- Afterwards, the partition is mounted by label so the numbering doesn't matter: `mount /dev/disk/by-label/lfs /mnt/lfs`

---

## Audio

### The problem

Every boot logged:

```
snd_hda_intel 0000:00:1f.3: Cannot probe codecs, giving up
```

The HD Audio controller driver was present, but there were no codec drivers for it to use.

### Identifying the hardware (on Fedora)

```
$ lspci -k | grep -A3 -i audio
00:1f.3 Multimedia audio controller: Intel Corporation 700 Series Chipset Family HD Audio (rev 11)
        Subsystem: Lenovo Device 3804
        Kernel driver in use: snd_hda_intel
        Kernel modules: snd_soc_avs, snd_sof_pci_intel_tgl, snd_hda_intel
--
01:00.1 Audio device: NVIDIA Corporation AD106M High Definition Audio Controller (rev a1)
        Kernel driver in use: snd_hda_intel

$ cat /proc/asound/card*/codec#* | grep -i codec
Codec: Realtek ALC257
Codec: Intel Raptorlake HDMI
Codec: Nvidia GPU a6 HDMI/DP
```

Conclusions:

- **Fedora uses the classic `snd_hda_intel` driver**, not Intel's newer SOF stack, so no extra audio firmware is needed
- **Speakers, headphones, and microphones** go through the **Realtek ALC257** codec
- **Intel Raptorlake HDMI** carries audio over the laptop's HDMI port
- **NVIDIA HDMI** belongs to the discrete GPU and was left alone

### Finding the right kernel options

Codec drivers have been reorganized in recent kernels, so the module names were taken from Fedora rather than guessed:

```
$ lsmod | grep -E 'snd_hda_codec|snd_hda_scodec'
snd_hda_codec_intelhdmi
snd_hda_codec_alc269
snd_hda_codec_realtek_lib
snd_hda_scodec_component
snd_hda_codec_nvhdmi
snd_hda_codec_generic
snd_hda_codec_hdmi
```

The ALC257 is handled by the **ALC269 family driver**. Each module name was then mapped to its kernel option by searching the kernel's Makefiles:

```
(chroot) root [ /usr/src/linux-7.1.8 ]# grep -rh -E "obj-.*(alc269|realtek-lib|scodec-component|codec-generic|codec-hdmi|intelhdmi)" --include=Makefile sound/hda/
obj-$(CONFIG_SND_HDA_CODEC_REALTEK_LIB) += snd-hda-codec-realtek-lib.o
obj-$(CONFIG_SND_HDA_CODEC_ALC269) += snd-hda-codec-alc269.o
obj-$(CONFIG_SND_HDA_CODEC_HDMI_GENERIC) += snd-hda-codec-hdmi.o
obj-$(CONFIG_SND_HDA_CODEC_HDMI_INTEL) += snd-hda-codec-intelhdmi.o
obj-$(CONFIG_SND_HDA_SCODEC_COMPONENT) += snd-hda-scodec-component.o
obj-$(CONFIG_SND_HDA_GENERIC) += snd-hda-codec-generic.o
```

This technique (running module from a working distro → Makefile → `CONFIG_` option) works for any driver and avoids relying on option names from guides written for older kernels.

### Kernel configuration

```bash
scripts/config -e SND_HDA_CODEC_REALTEK -e SND_HDA_CODEC_HDMI \
  -m SND_HDA_GENERIC \
  -m SND_HDA_CODEC_REALTEK_LIB \
  -m SND_HDA_CODEC_ALC269 \
  -m SND_HDA_SCODEC_COMPONENT \
  -m SND_HDA_CODEC_HDMI_GENERIC \
  -m SND_HDA_CODEC_HDMI_INTEL
make olddefconfig
```

`SND_HDA_CODEC_REALTEK` and `SND_HDA_CODEC_HDMI` were included as possible parent menus; `olddefconfig` drops options that don't exist in a given kernel.

### Userspace

From BLFS Chapter 42:

- **alsa-lib**, plus the recommended **alsa-ucm-conf** (device-specific use-case configuration that modern laptops often rely on)
- **alsa-utils** (`alsamixer`, `aplay`, `speaker-test`, `alsactl`)

alsa-lib's only dependency, systemd, was already installed.

### First boot with codecs

The kernel side worked immediately:

```
snd_hda_codec_alc269 hdaudioC1D0: ALC257: picked fixup  for PCI SSID 17aa:0000
snd_hda_codec_alc269 hdaudioC1D0: autoconfig for ALC257: line_outs=1 (0x14/0x0/0x0/0x0/0x0) type:speaker
snd_hda_codec_alc269 hdaudioC1D0:    hp_outs=1 (0x21/0x0/0x0/0x0/0x0)
snd_hda_codec_alc269 hdaudioC1D0:    inputs:
snd_hda_codec_alc269 hdaudioC1D0:      Internal Mic=0x12
snd_hda_codec_alc269 hdaudioC1D0:      Mic=0x19
input: HDA Intel PCH Mic as /devices/pci0000:00/0000:00:1f.3/sound/card1/input19
input: HDA Intel PCH Headphone as /devices/pci0000:00/0000:00:1f.3/sound/card1/input20
```

Speaker output, headphone output, internal mic, and external mic were all detected, on **card1**. The NVIDIA HDMI audio was **card0**.

Userspace did not work at first; see [Problem 21](#problem-21-audio-no-soundcards-found-and-wrong-default-card):

```
$ aplay -l
aplay: device_list:279: no soundcards found...
$ alsamixer
ALSA lib confmisc.c:855:(parse_card) [error.core] cannot find card '1'
...
cannot open mixer: No such file or directory
```

### Final configuration

```bash
sudo usermod -aG audio ferguson          # device access
```

`/etc/asound.conf`, selecting the Intel card **by name, not number**, since card numbers can change between boots just like the NVMe device names did:

```
defaults.pcm.card PCH
defaults.ctl.card PCH
```

Then in `alsamixer`: unmute (`M`) and raise Master, Speaker, and Headphone. Tested with `speaker-test -c 2 -t wav`, and saved with `sudo alsactl store` (written to `/var/lib/alsa/asound.state`).

**Result:** working speakers, headphones, and microphones.

---

## Linux-PAM

### Why it's needed

PAM (Pluggable Authentication Modules) puts authentication behind a configurable layer instead of each program checking `/etc/shadow` itself. It's a prerequisite for:

- **systemd-logind** sessions, which desktops, audio servers, and device access rely on
- Password policy and lockouts (libpwquality, `pam_faillock`) for the hardening pass
- Polkit and anything graphical that asks for privileges

### The risk

Installing PAM itself breaks nothing, because nothing uses it until it's rebuilt. The danger is the restrictive `/etc/pam.d/other` file the book installs: once a program is rebuilt with PAM, if it has no config file of its own, `other` denies it. Rebuilding Shadow or sudo without creating their PAM files would break console login or sudo.

**Mitigations:**

1. A fresh full backup immediately beforehand (`meridian-2026-10-11.tar.xz`)
2. The entire job done in **one chroot session** from Fedora, without rebooting until every piece was rebuilt and configured. A chroot root shell doesn't authenticate through PAM, so a mistake couldn't lock out the ability to fix it.
3. A defined test order after reboot, stopping at the first failure

### Kernel

`pam_loginuid.so` needs kernel auditing support:

```bash
scripts/config -e AUDIT
make olddefconfig
```

### Building Linux-PAM

The first `meson setup` failed:

```
../doc/man/meson.build:42:2: ERROR: Command `/usr/bin/xmllint --nonet --noout --xinclude --relaxng
http://docbook.org/xml/5.0/rng/docbookxi.rng misc_conv.3.xml` failed with status 5.
```

The `docs` option defaults to `auto`; finding `xmllint` (from libxml2) made meson attempt the man pages, but the DocBook schemas aren't installed. Confirmed the option name and rebuilt with docs disabled:

```
$ grep -n -i doc ../meson_options.txt
5:option('docs', type: 'feature', value: 'auto',
6:       description: 'Generate and install documentation')
```

```bash
meson setup ..        \
  --prefix=/usr       \
  --buildtype=release \
  -D docdir=/usr/share/doc/Linux-PAM-1.7.2 \
  -D docs=disabled &&
ninja
```

The pre-built documentation tarball was installed instead, so `man pam`, `man pam_unix`, and `man pam.conf` are available for the hardening pass.

Install sequence from the book:

1. Temporary all-deny `/etc/pam.d/other` → `ninja test` → remove it
2. `ninja install` and `chmod -v 4755 /usr/sbin/unix_chkpwd` (the setuid helper that lets unprivileged programs verify the current user's password)
3. The four generic files: `system-account`, `system-auth`, `system-session`, `system-password` (YESCRYPT)
4. The restrictive `other`, logging (`pam_warn`) and denying anything without its own config

### Rebuilding the PAM-aware programs

Each was rebuilt from a **fresh extract**, following its BLFS page (not the LFS Chapter 8 version):

| Package | PAM configuration created |
|---|---|
| **Shadow** | `login`, `passwd`, `su`, `chpasswd`, `newusers`, and a loop creating files for `chage`, `chfn`, `chgpasswd`, `chsh`, `groupadd`, `groupdel`, `groupmems`, `groupmod`, `useradd`, `userdel`, `usermod` |
| **systemd** (BLFS Chapter 12) | `pam_loginuid` and `pam_systemd` added to `system-session`; new `systemd-user`; a user environment generator so per-user services inherit `/etc/profile` variables |
| **sudo** | `/etc/pam.d/sudo`; the existing `/etc/sudoers.d/00-wheel` untouched |
| **OpenSSH** | Rebuilt with `--with-pam`; `/etc/pam.d/sshd` derived from `login`; `UsePAM yes` |

After Shadow:

```
(chroot) root [ /sources/shadow-4.20.2 ]# ls /etc/pam.d/
chage      chpasswd  groupdel   login     passwd          system-auth      useradd
chfn       chsh      groupmems  newusers  su              system-password  userdel
chgpasswd  groupadd  groupmod   other     system-account  system-session   usermod
```

**systemd notes:**

- Polkit is a *runtime* recommendation only; deferred until the graphical stack
- The stale `systemd-update-utmp-runlevel.service` was removed first, as the book warns for reinstalls
- Test suite: 1854 passed, 28 skipped, **1 failed** (`test-namespace`, `SIGABRT`). That test needs a booted system with specific kernel features; the book notes that tests run outside a booted system of the same version, or as root, can fail.
- `systemctl daemon-reexec` is a no-op in the chroot ("Running in chroot, ignoring command"). Rebooting has the same effect.

**OpenSSH note:** `UsePAM yes` does not re-enable password logins. `PasswordAuthentication no` and `KbdInteractiveAuthentication no` still apply; PAM handles the account and session side.

### Verification

Tested after reboot, in order:

```
Meridian login: ferguson
Password:
ferguson [ ~ ]$ su -
Password:
root [ ~ ]# exit
logout
ferguson [ ~ ]$ sudo whoami
[sudo] password for ferguson:
root
ferguson [ ~ ]$ loginctl
SESSION  UID USER     SEAT  LEADER CLASS   TTY  IDLE SINCE
      1 1001 ferguson seat0 507    user    tty1 no   -
      2 1001 ferguson -     589    manager -    no   -

2 sessions listed.
```

| Test | Result |
|---|---|
| Console login (`/etc/pam.d/login`) | Pass |
| `su -` (`/etc/pam.d/su`) | Pass |
| `sudo whoami` (`/etc/pam.d/sudo`) | Pass |
| SSH key login from Termux (`/etc/pam.d/sshd`) | Pass |
| `loginctl` | Session on `seat0` (registered with systemd-logind) plus a `manager` session (the per-user systemd instance) |

This also confirmed that `ferguson` is **UID 1001** on Meridian, consistent with `curtis` holding UID 1000 ([Problem 14](#problem-14-ssh-key-rejected-wrong-owner-on-ssh)).

An initial "SSH test" was accidentally run in the wrong direction (Meridian → phone) and got `Connection refused`, since Termux's SSH server listens on port 8022. The correct test, phone → Meridian, passed.

---

# 6. Problems Encountered and How They Were Solved

### Problem 1: Fedora host missing tools, and `yacc` not being Bison

**Symptom:** `version-check.sh` failed on `g++`, `texi2any`, and the `yacc` alias.

**Cause:** Fedora doesn't install the C++ compiler or Texinfo by default. Its `bison` package doesn't provide a `yacc` command, and the `byacc` package provides Berkeley yacc, which LFS rejects.

**Fix:**

```bash
sudo dnf install gcc-c++ texinfo
printf '#!/bin/sh\nexec /usr/bin/bison -y "$@"\n' | sudo tee /usr/bin/yacc
sudo chmod +x /usr/bin/yacc
```

The wrapper had to go in `/usr/bin`, not `/usr/local/bin`, because the check script locks `PATH` to `/usr/bin:/bin`.

---

### Problem 2: Disk choice with a LUKS-encrypted host

**Symptom:** No free space on the Fedora disk.

**Decision:** Wipe the unused Windows drive instead of a three-layer shrink (Btrfs → LUKS → partition) on the primary OS.

**Note:** The pre-wipe data check was skipped (`umount: /mnt/win: no mount point specified` showed the Windows partition had never been mounted for inspection). Nothing was needed from it, but in any real environment that check shouldn't be skipped.

---

### Problem 3: SELinux label warning on mount

```
mount: /mnt/lfs does not contain SELinux labels.
       You just mounted a file system that supports labels which does not
       contain labels, onto an SELinux box.
```

**Fix:** `sudo restorecon -Rv /mnt/lfs`. SELinux stayed enforcing for the entire build with no blocking denials.

---

### Problem 4: `wget-list` filename 404

```
HTTP ERROR response 404 [https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/wget-list-systemd]
Failed to open input file wget-list-systemd
```

`md5sum -c` then reported all 94 files missing.

**Cause:** The book names the file `wget-list-systemd`, but the versioned downloads directory names it `wget-list`.

**Fix:** Downloaded `wget-list`. It also included some SysV-edition tarballs (`sysvinit`, `sysklogd`, `udev-lfs`), which were ignored.

---

### Problem 5: Missing `$LFS` directory layout → permission denied

**Error** (Linux API Headers, Chapter 5):

```
  HDRINST usr/include/asm/ipcbuf.h
cp: cannot create directory '/mnt/lfs/usr': Permission denied
```

**Cause:** The Chapter 4.2 directory-layout commands had never run. The block had been pasted starting with `sudo -i`, which stops for a password, and the following lines were swallowed by the password prompt. Nothing visibly failed at the time; the problem only surfaced three sections later. The first retry failed the same way, for the same reason.

**Fix:** Run `sudo -i` alone, confirm the `root@fedora` prompt, **then** paste the commands.

---

### Problem 6: Commands run from the wrong directory

| Command | Error | Cause |
|---|---|---|
| `../configure` (Binutils) | `No such file or directory`, `real 0m0.001s` | `build/` created in `/home/lfs` instead of inside the source |
| `make mrproper` | `No rule to make target 'mrproper'` | Still in the GCC build directory |
| `cd linux-7.1.8` | `No such file or directory` | Tarball not yet extracted |
| `patch -Np1 -i ../glibc-fhs-1.patch` | Prompted `File to patch:` | Not inside `glibc-2.44` |
| `rm -v man3/crypt*` | `No such file or directory` | At `/`, not in the man-pages source |
| `tar -xf ../meson-1.12.0.tar.gz` | `Cannot open` | Already in `/sources`, so `../` pointed at `/` |
| `make install-sshd` | `No rule to make target` | In OpenSSH's source, not blfs-systemd-units |

**Pattern:** `cd /sources` → `tar -xf <pkg>` → `cd <pkg-dir>` → `pwd` → follow the book.

---

### Problem 7: Dirty source trees (M4 build failure)

```
In file included from m4.c:24:
../lib/getopt.h:89:10: fatal error: getopt-cdefs.h: No such file or directory
   89 | #include <getopt-cdefs.h>
      |          ^~~~~~~~~~~~~~~~
compilation terminated.
```

**Cause:** Extracted source folders from Chapters 5–7 had never been deleted. Re-extracting over an existing folder overwrites the source files but keeps stale build artifacts, including a Chapter 6 cross-compile configuration. `ls /sources` showed about 40 leftover directories.

**Fix:**

```bash
find /sources -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
```

That deletes directories only, one level deep, leaving tarballs and patches intact. Installed software lives in `/usr` and `/etc`, so no build progress was lost.

---

### Problem 8: Pkgconf / Meson confusion

```
python3: can't open file '/sources/meson-1.12.0/build/../meson-1.12.0/meson.py': [Errno 2] No such file or directory
```

**Cause:** Pkgconf's instructions unpack Meson **inside** the Pkgconf source tree. They were run inside the `meson-1.12.0` directory instead, and Meson was then pip-installed early as a misdiagnosed fix.

**Fix:** Removed the stray directory, redid Pkgconf from inside `pkgconf-3.0.5`. The later Meson section may need `--force-reinstall --no-deps`.

---

### Problem 9: Vim test suite hung

Progress stopped at `Test_terminal_paste_register()`, and Ctrl+C in the chroot had no effect.

```
$ ps -ef | grep -E 'make|vim' | grep -v grep
101  1928765  716510  0 20:03 ?  00:00:00 make -j1 test
...
101  1934803 1934802  0 20:07 ?  00:00:00 ../vim -f -u util/unix.vim ... test_terminal.vim
```

All processes showed 0 CPU time. UID `101` is the chroot's `tester` user, which has no name on Fedora.

**Fix:** `sudo pkill -9 -u 101` from the host, then install normally.

---

### Problem 10: Hardware clock set to local time

```
$ timedatectl | grep "RTC in local TZ"
Warning: The system is configured to read the RTC time in the local time zone.
          RTC in local TZ: yes
```

**Cause:** Leftover from the Windows dual-boot era.

```
$ sudo timedatectl set-local-rtc 0
Failed to set local RTC: Access denied
```

No SELinux denial (`ausearch` returned `<no matches>`), and the label was correct (`adjtime_t`). Workaround: `sudo hwclock --systohc --utc`. Status: see [Open Issues](#10-open-issues).

---

### Problem 11: ACL test failure

```
# TOTAL: 16
# PASS:  13
# XFAIL: 2
# FAIL:  1
```

The book documents `test/cp.test` as an expected failure, because Coreutils isn't built with ACL support yet. Confirm with `grep '^FAIL' test-suite.log`.

---

### Problem 12: Empty `$LFS` during unmount

```
[root@fedora ~]# umount -v $LFS/dev/shm $LFS/dev/pts
umount -v $LFS/{sys,proc,run,dev}
umount: /dev/shm: target is busy.
umount: /dev/pts: target is busy.
umount: /sys: target is busy.
umount: /proc: target is busy.
umount: /run: target is busy.
umount: /dev: target is busy.
```

**Cause:** `$LFS` wasn't set in a new root shell, so the commands targeted **Fedora's own** system mounts. All failed harmlessly as "busy". The same mistake with `chown -R` or `rm -rf` would have damaged the host.

**Fixes:**

1. `echo 'export LFS=/mnt/lfs' >> /root/.bash_profile`
2. Use **`${LFS:?}`** instead of `$LFS` in scripts. If the variable is empty, bash aborts with `LFS: parameter null or not set` instead of running the command.

---

### Problem 13: Wi-Fi configuration file mix-ups

The longest troubleshooting sequence of the build: four separate mistakes stacked on top of each other.

**Attempt 1: wrong program.** The command run was `wpa_supplicant` (the daemon), not `wpa_passphrase` (the config generator). The daemon's help text was piped through `tee` and **saved into the config file**.

**Attempt 2: stdin conflict.** In the `wpa_passphrase ... | sudo tee ...` pipeline, `sudo` asked for a password while `wpa_passphrase` was also waiting for the Wi-Fi password on the same keyboard. Fixed by caching sudo credentials first with `sudo -v`.

**Attempt 3: filename typo.** The correct config was saved as `wpa_supplicant-wlps0s20f3.conf`, with an extra `s`:

```
$ sudo ls -l /etc/wpa_supplicant/
-rw------- 1 root root 2249 Oct  9 22:25 wpa_supplicant-wlp0s20f3.conf    ← help text
-rw-r--r-- 1 root root  136 Oct  9 22:33 wpa_supplicant-wlps0s20f3.conf   ← real config
```

**Attempt 4: service name typo.** `wpa_supplicant@wlp0s20fe` (letter **e**) instead of `wlp0s20f3` (number **3**).

Throughout, the service failed with:

```
Failed to read or parse configuration '/etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf'.
wpa_supplicant@wlp0s20f3.service: Main process exited, code=exited, status=255/EXCEPTION
```

**The diagnostic that found it:** running wpa_supplicant in the foreground with debug output, which showed exactly what it was trying to parse:

```
$ sudo /usr/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf -d 2>&1 | head -40
Reading configuration file '/etc/wpa_supplicant/wpa_supplicant-wlp0s20f3.conf'
Line 1: unknown global field 'Successfully initialized wpa_supplicant'.
Line 2: unknown global field 'wpa_supplicant v2.12'.
Line 3: unknown global field 'Copyright (c) 2003-2026, Jouni Malinen <j@w1.fi> and contributors'.
...
Line 11: unknown global field 'usage:'.
```

**Final fix:** build the file in two separate steps, generating to `/tmp`, inspecting it, then installing it with `install -m 600`. Also: store the interface name in a variable (`IF=wlp0s20f3`), or use Tab completion, so it can't be mistyped.

**Lessons:**

1. `journalctl -u <service>` tells you *that* something failed; foreground debug mode (`-d`) tells you *why*
2. `ls -l` file sizes are evidence: 2249 bytes was far too large for a single network block
3. Commands like `0` vs `O` and `3` vs `e` are easy to confuse on a high-DPI console; tab completion prevents it
4. Separate steps beat clever pipelines when two programs need keyboard input

---

### Problem 14: SSH key rejected (wrong owner on `.ssh`)

```
$ ls -la ~
drwx------ 2 curtis   curtis   4096 Oct 10 18:48 .ssh
ls: cannot open directory '/home/ferguson/.ssh': Permission denied
```

**Cause:** `.ssh` was created from Fedora with `install -o 1000 -g 1000`, on the assumption that `ferguson` was UID 1000 on Meridian. On Meridian, UID 1000 belongs to a separate `curtis` account, so the directory belonged to the wrong user and sshd ignored the keys inside.

The journal also showed that password logins were still being accepted at that point:

```
sshd-session[698]: Accepted password for ferguson from 192.168.0.101 port 45650 ssh2
```

**Fix:**

```bash
sudo chown -R ferguson:ferguson ~/.ssh
sudo chmod 700 ~/.ssh
sudo chmod 600 ~/.ssh/authorized_keys
```

**Lesson:** use names, not numeric IDs, when setting ownership across two systems, unless the IDs have been verified on both.

---

### Problem 15: LLVM killed by the out-of-memory killer

See [The Rust toolchain and Git](#llvm-out-of-memory). Fixed by resuming with `ninja -j8` instead of 32 jobs, and closing memory-heavy applications on the host.

---

### Problem 16: No DNS inside the chroot after first boot

See [rustc: no DNS in the chroot](#rustc-no-dns-in-the-chroot). Fixed by copying Fedora's `resolv.conf` into the chroot's temporary `/run` at each session start.

---

### Problem 17: Firewall kernel missing netfilter tables

**Error at boot:**

```
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/7.1.8
iptables v1.8.13 (legacy): can't initialize iptables table 'filter': Table does not exist
```

**First fix attempt:**

```bash
scripts/config -e NETFILTER -e NETFILTER_ADVANCED \
  -e NF_CONNTRACK -e NETFILTER_XTABLES \
  -e NETFILTER_XT_MATCH_CONNTRACK -e NETFILTER_XT_MATCH_LIMIT \
  -e NETFILTER_XT_TARGET_LOG -e NF_LOG_SYSLOG \
  -e IP_NF_IPTABLES -e IP_NF_FILTER \
  -e IP6_NF_IPTABLES -e IP6_NF_FILTER
make olddefconfig
```

Only three of five options were applied:

```
CONFIG_NETFILTER_XT_MATCH_CONNTRACK=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP6_NF_IPTABLES=y
```

`IP_NF_FILTER` and `IP6_NF_FILTER`, the tables that actually hold the rules, didn't appear at all, not even as `is not set`. That means an unmet dependency was hiding them, and `olddefconfig` dropped them silently.

**Cause:** newer kernels put the legacy iptables tables behind a separate switch, **`CONFIG_NETFILTER_XTABLES_LEGACY`**.

**Fix:**

```bash
scripts/config -e NETFILTER_XTABLES_LEGACY \
  -e IP_NF_IPTABLES -e IP_NF_FILTER -e IP6_NF_IPTABLES -e IP6_NF_FILTER
make olddefconfig
```

```
CONFIG_NETFILTER_XTABLES_LEGACY=y
CONFIG_IP_NF_FILTER=m
CONFIG_IP6_NF_FILTER=m
```

The filter tables came out as modules (`=m`), which load automatically when the firewall script runs.

**Lesson:** after `scripts/config` and `olddefconfig`, always `grep` to confirm every option took. A missing option means a hidden dependency, and `make menuconfig` → `/` → the option name shows its **"Depends on"** line.

This rebuild was done natively over SSH from a phone, the first kernel rebuild done entirely on Meridian.

---

### Problem 18: NVMe device names swapped (near miss on Fedora's disk)

See [Expanding the root partition](#the-near-miss). The planned `resizepart` command named `nvme1n1`, which on that boot was the Fedora disk containing the EFI partition, `/boot`, and the encrypted root. Caught by running `lsblk` first and noticing `/boot/efi` under the target disk.

**Lessons:**

- Device names like `nvme0n1` and `nvme1n1` are assigned at boot in discovery order and are **not** guaranteed stable
- Before any destructive disk command, run `lsblk` and confirm the target disk shows only what you expect
- Refer to the partition by label or UUID (`/dev/disk/by-label/lfs`) wherever possible

---

### Problem 19: Package accidentally built on the Fedora host

alsa-lib was configured and compiled in a **Fedora** terminal (`ferguson@fedora:/mnt/lfs/sources/alsa-lib-1.2.16.1$`) instead of the chroot. Because `/mnt/lfs/sources` is reachable from both, nothing looked wrong until the prompt was noticed.

**Assessing the damage:**

- Compiling only writes inside the source directory; the risk is whether `sudo make install` ran, which would overwrite Fedora's alsa-lib
- Timestamps alone (`ls -l --time-style=+%H:%M`) were inconclusive, since they hide the date
- Asked the package manager instead:

```
$ rpm -V alsa-lib
$ file /usr/lib/libasound.so.2.0.0
/usr/lib/libasound.so.2.0.0: ELF 32-bit LSB shared object, Intel i386, version 1 (SYSV), dynamically linked, ...
```

`rpm -V` printed nothing, so every file belonging to Fedora's alsa-lib was unmodified. `/usr/lib` on Fedora holds 32-bit libraries, and the file there was still the 32-bit i686 copy, so the BLFS build (which installs to `/usr/lib`) had not overwritten it. Fedora was untouched.

**Fix:** deleted the host-built source tree and rebuilt from a fresh extract in the chroot. A build compiled against Fedora's libraries can't be used on Meridian.

**Prevention:** the `(chroot)` prompt indicator, and a separate, differently coloured terminal window for the chroot.

**Lesson:** `rpm -V <package>` is the right tool for "did anything modify this package's files?" on Fedora.

---

### Problem 20: Linux-PAM build tried to generate documentation

```
../doc/man/meson.build:42:2: ERROR: Command `/usr/bin/xmllint --nonet --noout --xinclude --relaxng
http://docbook.org/xml/5.0/rng/docbookxi.rng misc_conv.3.xml` failed with status 5.
```

**Cause:** meson's `docs` option defaults to `auto` and enables itself when `xmllint` is present, without checking whether the DocBook schemas are installed.

**Fix:** `-D docs=disabled`, after confirming the option name in `meson_options.txt`. Pre-built docs were installed from the BLFS tarball instead.

**Lesson:** `auto` feature options in meson enable themselves based on what happens to be installed; when a build fails on something optional, check `meson_options.txt` and disable it explicitly.

---

### Problem 21: Audio "no soundcards found" and wrong default card

The kernel had detected both cards, but as `ferguson`:

```
$ aplay -l
aplay: device_list:279: no soundcards found...
$ alsamixer
ALSA lib confmisc.c:855:(parse_card) [error.core] cannot find card '1'
ALSA lib conf.c:5211:(_snd_config_evaluate) [error.core] function snd_func_card_inum returned error: No such file or directory
...
cannot open mixer: No such file or directory
```

**Two separate causes:**

1. **Permissions.** The user had no access to `/dev/snd/*`. Fixed with `sudo usermod -aG audio ferguson` and a fresh login.
2. **Default card.** ALSA defaults to card 0, which was the NVIDIA HDMI output, not the laptop's speakers (card 1). Fixed with `/etc/asound.conf` selecting the Intel card **by name** (`PCH`), so it survives card renumbering.

**Lesson:** "no soundcards found" while `dmesg` shows cards being registered is almost always permissions, not drivers.

---

### Problem 22: Stacked mount on `/mnt/lfs`

During a backup, `findmnt` showed the partition mounted twice on the same path:

```
TARGET     SOURCE         FSTYPE OPTIONS
/mnt/lfs   /dev/nvme1n1p1 ext4   rw,relatime,seclabel
└─/mnt/lfs /dev/nvme1n1p1 ext4   rw,relatime,seclabel
```

Harmless (the backup was fine), and cleared with one `umount /mnt/lfs`. The chroot script's mount line already had a `findmnt /mnt/lfs ||` guard, so the extra layer came from an earlier manual mount.

---

### Minor issues

- **Binutils `ls` mismatch:** `ls $LFS/tools/bin` once returned `No such file or directory`, then succeeded; verified with `--version`
- **`make & make install`** (single `&`) briefly used instead of `&&`; harmless that time
- **Groff placeholder:** `PAGE=<paper_size>` typed literally → `bash: paper_size: No such file or directory`
- **`~/etc/skel` vs `/etc/skel`:** keeping the `~` produced `/root/etc/skel/.profile: No such file or directory`
- **`wget` URL typo:** `https://www/linuxfromscratch.org/` (slash instead of dot) → `unable to resolve host address 'www'`
- **iwd and nftables** were planned but aren't in BLFS 13.1; replaced with wpa_supplicant and iptables
- **Kernel messages over the login prompt** after i915 became a module; fixed with `quiet loglevel=3`
- **SSH test in the wrong direction:** `ssh u0_a245@192.168.0.101` from Meridian to the phone got `Connection refused` (Termux's sshd uses port 8022); the intended test was phone → Meridian
- **`aplay -1` instead of `aplay -l`:** `invalid option -- '1'`, another `1`/`l` confusion on the console font
- **systemd `test-namespace` failure** in the chroot; expected outside a booted system

---

# 7. Security Posture

| Area | Configuration |
|---|---|
| Accounts | Daily use as an unprivileged user; root via `sudo` (wheel group) |
| Authentication framework | Linux-PAM; restrictive `/etc/pam.d/other` logs and denies any PAM-aware program without its own config |
| Sessions | Every login registered with systemd-logind (`pam_loginuid`, `pam_systemd`); kernel auditing enabled for login UIDs |
| Device access | Audio via the `audio` group |
| Password hashing | YESCRYPT (Shadow `login.defs`) |
| Root history | Disabled (`unset HISTFILE` for root in `/etc/profile`) |
| SSH: authentication | Public key only; `PasswordAuthentication no`, `KbdInteractiveAuthentication no` |
| SSH: root | `PermitRootLogin no`; verified by a refused root login in the journal |
| SSH: privilege separation | Unprivileged `sshd` user (UID 50) |
| SSH: PAM | `UsePAM yes` for account and session handling; password authentication remains disabled |
| Firewall: inbound | Default **DROP** on IPv4 **and** IPv6 |
| Firewall: allowed | Loopback, established/related, DHCP, SSH and ping **from LAN only**, ICMPv6 |
| Firewall: forwarding | Policy DROP, `ip_forward = 0` |
| Kernel network hardening | SYN cookies, reverse-path filtering, no ICMP redirects, no source routing, martian logging |
| Logging | Rate-limited logging of dropped packets |
| TLS trust | Single system CA store (make-ca), weekly updates (`update-pki.timer`); pip uses the system store |
| Secrets on disk | Wi-Fi PSK file mode `600`; `/etc/.git` mode `700` |
| Change tracking | `/etc` under Git |
| Kernel | Stack protector (strong), KASLR, `LEGACY_TIOCSTI` disabled, `FW_LOADER_USER_HELPER` disabled |
| Updates | Manual; tracked against BLFS's **Vulnerabilities** page (no package manager) |

### Attack surface check

```bash
sudo ss -tulpn
```

Only sshd should be listening.

---

# 8. Final System Configuration

| Item | Value |
|---|---|
| Name / hostname | Meridian / `meridian` |
| Kernel | 7.1.8, custom config; NVMe/ext4/EFI stub built in; Wi-Fi, i915, netfilter filter tables, and HDA codecs as modules; auditing enabled; no initramfs |
| Init | systemd 261.2 |
| C library | Glibc 2.44 |
| Compilers | GCC 16.2.0, LLVM 22.1.8 (shared library build), rustc 1.97.1 |
| Root filesystem | ext4, label `lfs`, 476.9 GB (whole second NVMe; device name varies by boot) |
| Bootloader | Fedora's GRUB, with a primary entry plus a fallback-kernel entry |
| Kernel command line | `root=PARTUUID=... ro quiet loglevel=3` |
| Locale | `en_CA.UTF-8`; console uses `C.UTF-8` |
| Timezone | America/Halifax |
| Console font | `LatGrkCyr-12x22` |
| Login banner | Custom "Meridian" art in `/etc/issue` |
| Audio | ALSA; Realtek ALC257 via `snd_hda_codec_alc269`; default card `PCH` set by name in `/etc/asound.conf` |
| Authentication | Linux-PAM; Shadow, systemd, sudo, and OpenSSH rebuilt with PAM; systemd-logind sessions |
| Network | systemd-networkd (DHCP on `en*` and `wl*`), wpa_supplicant on `wlp0s20f3` |
| IP | `192.168.0.12/24` (DHCP) |
| DNS | systemd-resolved |
| Firmware loaded | `iwlwifi-so-a0-gf-a0-89.ucode`, `i915/adls_dmc_ver2_01.bin`, `i915/tgl_guc_70.bin`, `regulatory.db` |
| Users | `ferguson` (UID 1001; wheel, audio), `curtis` (UID 1000), `sshd` (UID 50), root |
| Remote access | OpenSSH 10.5p1, key-only |
| Firewall | iptables 1.8.13 (legacy backend), BLFS systemd unit |
| Config tracking | Git repo in `/etc` (local only) |
| Editor | nano (`EDITOR=nano`) |

### BLFS packages built so far

sudo · libtasn1 · p11-kit · make-ca · wget · libnl · wpa_supplicant · nano · OpenSSH · blfs-systemd-units · cURL · libssh2 · CMake · LLVM · rustc · Git · iptables · alsa-lib · alsa-ucm-conf · alsa-utils · Linux-PAM

**Rebuilt with PAM support:** Shadow · systemd · sudo · OpenSSH

---

# 9. Lessons Learned

1. **Verify state, don't assume it.** The worst problem (the missing directory layout) failed silently and surfaced three sections later. A quick `ls` after each structural step catches this immediately.
2. **Never paste commands after `sudo -i` in one block.** The password prompt eats the following lines.
3. **Use `${LFS:?}`, not `$LFS`.** One character turns "silently operate on the host" into "refuse to run".
4. **The chroot isolates files, not the kernel.** Anything that touches the running kernel (firewall rules, `/proc/sys`, module loading) affects the host.
5. **Built-in vs module matters without an initramfs.** Storage and filesystem drivers for the root must be built in; drivers that need firmware files (Wi-Fi, GPU) must be modules.
6. **After `scripts/config`, grep for every option.** `olddefconfig` silently drops anything whose dependencies aren't met.
7. **Kernel interfaces move.** `NETFILTER_XTABLES_LEGACY` didn't exist in older kernels; online guides written before it will be wrong.
8. **Debug output beats guessing.** Foreground mode with `-d` explained in one screen what `journalctl` couldn't.
9. **File sizes and timestamps are evidence.** They identified which wpa_supplicant config was junk.
10. **Typos in identifiers are a real failure mode.** `wlps0s20f3`, `wlp0s20fe`, `www/`: variables and tab completion prevent them.
11. **Use names, not numeric IDs, across systems.** The `curtis`/UID 1000 mismatch broke SSH.
12. **Parallelism is limited by memory, not just cores.** Heavy C++ builds need roughly 2 GB per job.
13. **Check the book before planning around a package.** iwd and nftables weren't in BLFS 13.1.
14. **One package directory at a time.** Clean up right after installing.
15. **Secrets end up in surprising places.** `/etc/.git` holds a copy of `/etc/shadow`.
16. **Document as you go.** Part I of this log was reconstructed afterwards.
17. **`lsblk` before every destructive disk command.** Device names swapped between boots, and only a pre-check stopped a resize from targeting Fedora's EFI partition.
18. **Check which machine your shell is on before building.** A shared `/sources` directory makes host and chroot terminals look alike; the prompt is the only reliable signal.
19. **Ask the package manager, not timestamps.** `rpm -V` answered "was Fedora modified?" definitively.
20. **Learn driver names from a working system.** `lsmod` on Fedora → kernel Makefiles → `CONFIG_` options found the exact audio codec options for a kernel whose naming had changed.
21. **Identify devices by name, not number.** NVMe disks, sound cards, and UIDs all turned out to be numbered differently than assumed. Labels, UUIDs, and card IDs like `PCH` don't move.
22. **For risky changes, keep a way back in.** Doing the whole PAM rebuild from a chroot root shell, which doesn't authenticate through PAM, meant a mistake couldn't lock out the fix.

---

# 10. Open Issues

| Issue | Status / plan |
|---|---|
| **Discrete GPU** | NVIDIA AD106M unconfigured; the desktop will run on Intel graphics |
| **Login banner glyphs** | Block characters render as substitutes in `LatGrkCyr-12x22`; switch to Terminus (`ter-v24n`/`ter-v28n`) |
| **Polkit** | Deferred until the graphical stack (pulls in a JavaScript engine) |
| **Kernel `AUDIT`** | Confirm the running kernel was rebuilt with `CONFIG_AUDIT=y` (`zgrep`/`grep AUDIT` on the installed config) |
| **Old backup** | `meridian-2026-10-10.tar.xz` can be deleted now that PAM is verified |
| **SSH password auth** | Confirm with `sudo sshd -T \| grep -iE 'passwordauth\|kbdinteractive\|permitrootlogin'`: all should be `no`. sshd uses the **first** occurrence of each setting |
| **Fedora RTC** | Confirm `timedatectl` shows `RTC in local TZ: no` |
| **`curtis` account** | Owns UID 1000 on Meridian; keep or remove (`userdel -r curtis`) |
| **Outbound SSH** | Generate Meridian's own client key and authorize it on other LAN hosts |
| **Remote servers** | Upgrade OpenSSH on LAN hosts for post-quantum key exchange |
| **Meson** | Was pip-installed early; reinstall properly at its BLFS section |
| **Console font** | Optionally move to Terminus 24/28 (`ter-v24n`/`ter-v28n`) |

---

# 11. Next Steps

### Direction: a hardened minimal system with a GUI on demand

Rather than a full desktop environment, Meridian will stay a server-style base with a lightweight graphical session started by hand. There's no display manager: the system boots to the text console, and the GUI starts only when needed. When it isn't running, none of the graphical stack is running.

**Compositor choice: Wayfire** (BLFS's Wayland compositor, built on wlroots). Under X11, any application can read keystrokes and capture the contents of other windows; Wayland isolates applications from each other by design. That's a meaningful architectural advantage for a security-focused system. Openbox (X11) is the fallback if Wayfire proves troublesome, and Sway (built on the same wlroots, but outside BLFS) is an alternative with a larger community.

### Order

1. **Close the open security items:** confirm SSH password logins are off (`sudo sshd -T`), audit listening ports with `ss -tulpn`
2. **Graphics stack:** Mesa (using the system LLVM already built), libdrm, Wayland, wlroots, libinput, seat handling via systemd-logind, working back from Wayfire's dependency list
3. **Wayfire**, a Wayland terminal, then **Polkit**
4. **Deep hardening pass:** password quality (libpwquality), lockouts (`pam_faillock`), kernel lockdown and module signing, stricter `sysctl`s, `noexec` on `/tmp`, systemd service sandboxing, outbound firewall rules, Tripwire file integrity
5. **VM image:** a portable copy of Meridian for safe testing (UEFI firmware, NVMe or SATA disk, e1000e network)
6. **Publish:** a public `meridian` repository with curated configs and this log

---

# Appendix A: Command Reference

### Entering the chroot (from Fedora)

```bash
sudo -i
```

Then:

```bash
export LFS=/mnt/lfs
findmnt /mnt/lfs || mount -v /dev/disk/by-uuid/efddce50-298d-479a-a4c2-65eba5023ffc ${LFS:?}

mount -v --bind /dev ${LFS:?}/dev
mount -vt devpts devpts -o gid=5,mode=0620 ${LFS:?}/dev/pts
mount -vt proc proc ${LFS:?}/proc
mount -vt sysfs sysfs ${LFS:?}/sys
mount -vt tmpfs tmpfs ${LFS:?}/run
if [ -h ${LFS:?}/dev/shm ]; then
  install -v -d -m 1777 ${LFS:?}$(realpath /dev/shm)
else
  mount -vt tmpfs -o nosuid,nodev tmpfs ${LFS:?}/dev/shm
fi

# DNS for the chroot (Meridian's resolv.conf points into /run)
mkdir -p ${LFS:?}/run/systemd/resolve
cp /etc/resolv.conf ${LFS:?}/run/systemd/resolve/stub-resolv.conf

chroot "${LFS:?}" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" \
    TESTSUITEFLAGS="-j$(nproc)" \
    /bin/bash --login
```

### Mounting the partition safely (device names vary by boot)

```bash
findmnt /mnt/lfs || mount /dev/disk/by-label/lfs /mnt/lfs
lsblk -o NAME,SIZE,LABEL,MOUNTPOINTS      # identify disks by label before any disk operation
```

### Full backup (from Fedora)

```bash
export LFS=/mnt/lfs
umount -v ${LFS:?}/dev/shm ${LFS:?}/dev/pts 2>/dev/null
umount -v ${LFS:?}/{sys,proc,run,dev} 2>/dev/null
findmnt -R ${LFS:?}                       # must show only /mnt/lfs itself
cd ${LFS:?}
tar -I 'xz -T0' -cpf /root/meridian-$(date +%F).tar.xz --exclude=./sources .
```

### Leaving the chroot

```bash
exit
umount -v ${LFS:?}/dev/shm ${LFS:?}/dev/pts
umount -v ${LFS:?}/{sys,proc,run,dev}
```

### Kernel rebuild (from `/usr/src/linux-7.1.8`)

```bash
cp -v /boot/vmlinuz-7.1.8-lfs-13.1-systemd /boot/vmlinuz-7.1.8-lfs-13.1-systemd.good
scripts/config <options>
make olddefconfig
grep -E 'CONFIG_(<OPTION1>|<OPTION2>)=' .config      # verify every option
make -j16
make modules_install
cp -v arch/x86/boot/bzImage /boot/vmlinuz-7.1.8-lfs-13.1-systemd
```

No `make mrproper` on rebuilds; it would wipe the config and all compiled objects.

### Updating Fedora's GRUB

```bash
sudo nano /etc/grub.d/40_custom
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

### Committing a config change

```bash
cd /etc && sudo git add -A && sudo git commit -m "<what changed>"
```

### Diagnostics

| Need | Command |
|---|---|
| Boot log | `journalctl -b` |
| Kernel messages | `sudo dmesg` / `journalctl -k` |
| Service status | `systemctl status <svc>` |
| Service log | `sudo journalctl -u <svc> -n 30 --no-pager` |
| Firmware loading | `sudo dmesg \| grep -iE 'firmware\|failed with error'` |
| Interfaces and addresses | `ip addr` |
| Wi-Fi radio block | `sudo rfkill list` |
| Listening ports | `sudo ss -tulpn` |
| Firewall rules | `sudo iptables -L -n -v`, `sudo ip6tables -L -n -v` |
| Dropped packets | `sudo journalctl -k \| grep FIREWALL` |
| Effective sshd config | `sudo sshd -T` |
| Memory during builds | `watch -n 2 free -h` |
| Which process holds a mount | `fuser -vm <path>` |
| Sound cards (kernel view) | `cat /proc/asound/cards` |
| Sound devices (user view) | `aplay -l` |
| Codec detection | `sudo dmesg \| grep -i -E 'snd\|hda\|alc'` |
| Login sessions | `loginctl` |
| PAM configuration | `ls /etc/pam.d/` |
| Were a Fedora package's files modified? | `rpm -V <package>` |
| Map a module to its kernel option | `grep -rn "<module-name>" --include=Makefile <dir>` |

---

# Appendix B: What Not to Publish

The `/etc` repo stays local. A public portfolio repository should contain hand-picked copies only.

### Never publish

| File | Why |
|---|---|
| `/etc/shadow`, `/etc/gshadow` | Password hashes |
| `/etc/ssh/ssh_host_*_key` | SSH host private keys; allows impersonating the machine |
| `/etc/wpa_supplicant/*.conf` | Wi-Fi network key (`psk=`) |
| `~/.ssh/id_*` (no `.pub`) | Private client keys |
| `/etc/sudoers.d/*` | Privilege configuration (low risk, but no reason to share) |
| Anything with `psk=`, `password`, `secret`, `token` | Self-explanatory |

### Safe to publish (after reading through)

| File | Notes |
|---|---|
| `/etc/ssh/sshd_config` | Shows the hardening choices |
| `/etc/systemd/scripts/iptables` | The firewall ruleset |
| `/etc/systemd/network/*.network` | Network configuration |
| `/etc/vconsole.conf`, `/etc/locale.conf` | Harmless |
| `/usr/src/linux-7.1.8/.config` | The kernel configuration |
| This build log | Remove anything you consider private (MAC addresses, LAN IPs) |

### Suggested repository layout

```
meridian/
├── README.md                  ← this build log
├── configs/
│   ├── sshd_config
│   ├── iptables
│   ├── 10-eth-dhcp.network
│   ├── 20-wlan.network
│   ├── vconsole.conf
│   └── kernel-config
└── scripts/
    └── lfs-chroot.sh          ← Appendix A chroot script
```

Showing that you know which files must never be published is itself a point worth making in a security portfolio.
