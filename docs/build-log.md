# Linux From Scratch 13.1-systemd — Build Log

**Builder:** Curtis Ferguson
**Book version:** LFS 13.1-systemd
**Host:** Fedora 44 (KDE), laptop
**Result:** LFS boots successfully on bare metal, dual-booted from Fedora's GRUB
**Completed:** October 2026

---

## Contents

1. [Overview](#overview)
2. [Hardware and Host Environment](#hardware-and-host-environment)
3. [Key Decisions](#key-decisions)
4. [Build Walkthrough by Chapter](#build-walkthrough-by-chapter)
5. [Problems Encountered and Fixes](#problems-encountered-and-fixes)
6. [Final System Configuration](#final-system-configuration)
7. [Lessons Learned](#lessons-learned)
8. [Next Steps](#next-steps)

---

## Overview

Linux From Scratch is a book-guided process for building a complete Linux system from source code: a cross-compiled toolchain, a temporary system built inside a chroot, then roughly 80 packages compiled into the final system, a custom-configured kernel, and boot configuration.

This build was done on real hardware (not a VM), on a dedicated partition on a second NVMe drive, booted through the host's existing GRUB bootloader.

**Build time reference:** 1 SBU (Standard Build Unit, measured on Binutils Pass 1) = **60 seconds** on this machine, so SBU values in the book map roughly to minutes.

---

## Hardware and Host Environment

| Component | Detail |
|---|---|
| CPU | 32 logical cores (`nproc` = 32) |
| Disk 1 (`nvme0n1`) | SK Hynix 1 TB — Fedora (LUKS2-encrypted Btrfs, EFI, /boot) |
| Disk 2 (`nvme1n1`) | Micron 512 GB — formerly an unused Windows install; now hosts LFS |
| Host OS | Fedora 44, kernel 7.2.7, SELinux enforcing, root account locked |
| Swap | zram (8 GB), no swap partition |
| Firmware | 64-bit UEFI |

### Host disk layout before the build

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

---

## Key Decisions

### 1. Real hardware dual boot instead of a VM

A VM with snapshots is the safer first-time path. I chose a real partition so the end result is a system that actually boots on my laptop, accepting that kernel debugging would be slower without snapshots. Fedora stayed untouched as a fallback.

### 2. Second NVMe drive instead of shrinking Fedora

Fedora's disk was entirely consumed by a LUKS-encrypted Btrfs volume. Shrinking it would have required resizing Btrfs, then the LUKS container, then the partition, in the correct order, with a mistake risking the primary OS.

The second drive held a Windows install I hadn't signed into in months, and it had no EFI System Partition of its own. I wiped it and gave LFS a 100 GB partition, leaving the rest free.

### 3. Unencrypted LFS root

Keeping the LFS partition unencrypted means Fedora's GRUB can read the LFS kernel directly, and the LFS kernel doesn't need LUKS support or an initramfs.

### 4. Fedora's GRUB boots LFS (no `grub-install` from LFS)

Running `grub-install` from LFS would overwrite Fedora's bootloader on the shared EFI partition. Instead, I added a custom menu entry to Fedora's GRUB (`/etc/grub.d/40_custom`). LFS's own GRUB was still built (64-bit UEFI target) so LFS could be made independently bootable later.

### 5. systemd edition

Chose the systemd book to match Fedora's init system and tooling familiarity.

### 6. UUID / PARTUUID everywhere

NVMe device names (`nvme0` vs `nvme1`) can swap between boots, so all references use UUIDs:

- Filesystem UUID: `efddce50-298d-479a-a4c2-65eba5023ffc` (used in fstab and GRUB's `search`)
- Partition UUID: `d74238bb-83c9-4823-825f-2a1f676ab9bc` (used for the kernel's `root=`; `root=UUID=` would require an initramfs)

### 7. Built-in drivers, no initramfs

NVMe, ext4, EFI stub, and EFI-related filesystems were compiled into the kernel (`=y`) rather than as modules, since there's no initramfs to load modules before the root filesystem is mounted.

### 8. Selective test suites

Ran the test suites the book marks as critical (GMP and others) and skipped or abandoned optional ones when they were slow or hung (Elfutils/Libelf, Vim).

---

## Build Walkthrough by Chapter

### Chapter 2 — Host preparation

Ran the book's `version-check.sh`. Three failures on a stock Fedora install:

```
ERROR: Cannot find g++ (GCC (C++))
ERROR: Cannot find texi2any (Texinfo)
ERROR: yacc is NOT Bison
...
version-check.sh: line 76: g++: command not found
ERROR: g++ does NOT work
```

Fix: see [Problem 1](#problem-1-fedora-host-missing-tools-and-yacc-not-being-bison). After the fix, every check returned `OK`.

#### Partitioning (on the second NVMe)

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

#### Mounting

```bash
export LFS=/mnt/lfs
sudo mkdir -pv $LFS
sudo mount -v -t ext4 /dev/nvme1n1p1 $LFS
```

Produced an SELinux warning (see [Problem 3](#problem-3-selinux-label-warning-on-mount)).

Persistent mount added to Fedora's `/etc/fstab`:

```
UUID=efddce50-298d-479a-a4c2-65eba5023ffc  /mnt/lfs  ext4  defaults  1 2
```

### Chapter 3 — Packages

```bash
cd $LFS/sources
wget https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/md5sums
wget https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/wget-list
wget --input-file=wget-list --continue --directory-prefix=$LFS/sources
md5sum -c md5sums
sudo chown root:root $LFS/sources/*
```

Result: 98 files, 628 MB, all 94 checksummed packages and patches `OK`. (See [Problem 4](#problem-4-wget-list-filename-404) for the initial 404.)

### Chapter 4 — Final preparations

- Created the `$LFS` directory layout (`etc`, `var`, `usr/{bin,lib,sbin}`, `lib64`, `tools`, plus `bin`/`lib`/`sbin` symlinks into `usr`)
- Created the unprivileged `lfs` build user on the host
- Set `MAKEFLAGS=-j$(nproc)` (32 jobs) in the `lfs` user's `.bashrc`

Adaptation for Fedora's locked root account: every "as root" step used `sudo` or a `sudo -i` shell, and `su - lfs` became `sudo su - lfs`.

### Chapter 5 — Cross-toolchain

| Package | Notes |
|---|---|
| Binutils Pass 1 | Timed for SBU: `real 1m0.166s` |
| GCC Pass 1 | mpfr/gmp/mpc extracted inside the GCC tree; `lib64` → `lib` sed verified with `diff`; `limits.h` step completed |
| Linux API Headers | Failed on copy (see [Problem 5](#problem-5-missing-lfs-directory-layout--permission-denied)) |
| Glibc | Sanity check passed |
| Libstdc++ | Built from a fresh GCC extract |

Binutils verification:

```
$ $LFS/tools/bin/x86_64-lfs-linux-gnu-ld --version | head -1
GNU ld (GNU Binutils) 2.47.20260726
```

Glibc sanity check (the critical one):

```bash
echo 'int main(){}' | $LFS_TGT-gcc -x c -
readelf -l a.out | grep ': /lib'
```

```
[Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]
```

### Chapter 6 — Cross-compiling temporary tools

Built M4, Ncurses, Bash, and the rest of the temporary tools through GCC Pass 2. All installs used `DESTDIR=$LFS`.

### Chapter 7 — Chroot and temporary system

- Changed ownership of `$LFS` from `lfs` to `root`
- Mounted virtual kernel filesystems (`/dev`, `/dev/pts`, `/proc`, `/sys`, `/run`)
- Entered the chroot and built the remaining temporary tools
- **Backup:** after the 7.15 cleanup, unmounted the virtual filesystems and created a full backup using multithreaded xz:

```bash
cd $LFS
tar -I 'xz -T0' -cpf $HOME/lfs-temp-tools-13.1-systemd.tar.xz .
```

Saved to `/root/` and copied to `/home/ferguson/`.

#### Re-entering the chroot after a reboot or suspend

```bash
sudo -i
export LFS=/mnt/lfs
findmnt /mnt/lfs || mount -v /dev/disk/by-uuid/efddce50-298d-479a-a4c2-65eba5023ffc $LFS
mount -v --bind /dev $LFS/dev
mount -vt devpts devpts -o gid=5,mode=0620 $LFS/dev/pts
mount -vt proc proc $LFS/proc
mount -vt sysfs sysfs $LFS/sys
mount -vt tmpfs tmpfs $LFS/run
if [ -h $LFS/dev/shm ]; then
  install -v -d -m 1777 $LFS$(realpath /dev/shm)
else
  mount -vt tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
fi
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" TESTSUITEFLAGS="-j$(nproc)" \
    /bin/bash --login
```

### Chapter 8 — Final system (~80 packages)

Notable steps and choices:

- **Glibc locales:** installed the book's test-coverage set plus `en_CA.UTF-8`
- **Timezone:** `ln -sfv /usr/share/zoneinfo/America/Halifax /etc/localtime`
- **GMP:** critical test suite; required ≥199 passing tests before install
- **Groff:** `PAGE=letter` (Canada uses US Letter)
- **Shadow:** YESCRYPT password hashing, `/var/mail`, `/bin` and `/sbin` removed from `PATH` in `login.defs`
- **Python:** OpenSSL 4 compatibility patch applied; `/etc/pip.conf` created to suppress root and version-check warnings
- **GRUB:** built for 64-bit UEFI only; 32-bit UEFI skipped
- **Libelf:** installed only the library, test suite skipped

### Chapter 9 — System configuration

**Network** (`/etc/systemd/network/10-eth-dhcp.network`): DHCP with a wildcard match so the interface name doesn't matter.

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

Disabled because on a laptop that's often unplugged, it stalls boot about 2 minutes waiting for a network.

**DNS:** systemd-resolved (default). Unbound is used on the host but isn't available in base LFS; to be revisited after building it from BLFS.

**Hosts:** DHCP, so no static IP line; `localhost` handled by `nss-myhostname`.

**Console:** `FONT=Lat2-Terminus16`, default US keymap (matched Fedora's `KEYMAP="us"`).

**Locale:** verified before writing config:

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

`/etc/locale.conf`: `LANG=en_CA.UTF-8`, plus the book's `/etc/profile`.

**Clock:** see [Problem 10](#problem-10-hardware-clock-set-to-local-time).

### Chapter 10 — Making LFS bootable

**fstab:**

```
# file system                               mount-point  type  options   dump  fsck
UUID=efddce50-298d-479a-a4c2-65eba5023ffc   /            ext4  defaults  1     1
```

No swap line (no swap partition), no ESP entry (LFS never needs to touch Fedora's boot partition).

**Kernel 7.1.8:** started from `make defconfig`, then applied the book's required options with `scripts/config` instead of navigating `menuconfig` option by option:

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

Verified the boot-critical options before compiling:

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

Source tree kept in `/usr/src/linux-7.1.8` (root-owned) for later rebuilds when adding Wi-Fi and GPU drivers.

**Boot entry in Fedora's GRUB** (`/etc/grub.d/40_custom`):

```
menuentry "LFS 13.1-systemd" {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root efddce50-298d-479a-a4c2-65eba5023ffc
    linux /boot/vmlinuz-7.1.8-lfs-13.1-systemd root=PARTUUID=d74238bb-83c9-4823-825f-2a1f676ab9bc ro
}
```

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
sudo grub2-editenv - unset menu_auto_hide   # Fedora hides the menu by default
```

Secure Boot must be off; Fedora's shim/GRUB will refuse an unsigned kernel. Check with `mokutil --sb-state`.

### Chapter 11 — First boot

**LFS booted successfully on the first attempt.**

---

## Problems Encountered and Fixes

### Problem 1: Fedora host missing tools, and `yacc` not being Bison

**Symptom:** `version-check.sh` failed on `g++`, `texi2any`, and the `yacc` alias.

**Cause:** Fedora doesn't install the C++ compiler or Texinfo by default, and its `bison` package doesn't provide a `yacc` command. The `byacc` package does, but that's Berkeley yacc, which LFS rejects.

**Fix:**

```bash
sudo dnf install gcc-c++ texinfo
printf '#!/bin/sh\nexec /usr/bin/bison -y "$@"\n' | sudo tee /usr/bin/yacc
sudo chmod +x /usr/bin/yacc
```

The wrapper had to go in `/usr/bin`, not `/usr/local/bin`, because the script locks `PATH` to `/usr/bin:/bin`.

**Result:** `OK: yacc is Bison`, `OK: g++ works`, `OK: Texinfo 7.2 >= 5.0`.

---

### Problem 2: Disk choice with a LUKS-encrypted host

**Symptom:** No free space on the Fedora disk; the entire 951 GB partition was a LUKS container holding Btrfs.

**Decision:** Wiped the unused Windows install on the second NVMe rather than performing a three-layer shrink (Btrfs → LUKS → partition) on the primary OS. See [Key Decision 2](#2-second-nvme-drive-instead-of-shrinking-fedora).

**Note:** The pre-wipe data check was skipped (`umount: /mnt/win: no mount point specified` showed it had never been mounted). No data turned out to be needed, but in a real environment that check should never be skipped.

---

### Problem 3: SELinux label warning on mount

**Error:**

```
mount: /mnt/lfs does not contain SELinux labels.
       You just mounted a file system that supports labels which does not
       contain labels, onto an SELinux box. It is likely that confined
       applications will generate AVC messages and not be allowed access to
       this file system.
```

**Cause:** A freshly formatted ext4 filesystem has no SELinux contexts.

**Fix:**

```bash
sudo restorecon -Rv /mnt/lfs
```

SELinux was left enforcing throughout; no AVC denials blocked the build.

---

### Problem 4: `wget-list` filename 404

**Error:**

```
HTTP ERROR response 404 [https://www.linuxfromscratch.org/lfs/downloads/13.1-systemd/wget-list-systemd]
Failed to open input file wget-list-systemd
Nothing to do - goodbye
```

`md5sum -c` then reported all 94 files as `FAILED open or read`, since nothing had been downloaded.

**Cause:** The book's section names the file `wget-list-systemd`, but in the versioned downloads directory it's just `wget-list`.

**Fix:** Downloaded `wget-list` instead. All checksums passed.

**Side effect:** That list included some SysV-edition tarballs (`sysvinit`, `sysklogd`, `udev-lfs`), which were harmless and ignored.

---

### Problem 5: Missing `$LFS` directory layout → permission denied

**Error** (during Linux API Headers, Chapter 5):

```
  HDRINST usr/include/asm/ipcbuf.h
cp: cannot create directory '/mnt/lfs/usr': Permission denied
```

**Cause:** The Chapter 4.2 directory-layout commands had never taken effect. The block had been pasted starting with `sudo -i`, which stops for a password; the lines after it were swallowed by the password prompt. Nothing errored visibly at the time. The failure only surfaced three sections later.

Confirmed: `ls -la /mnt/lfs` showed only `lost+found`, `sources`, and `tools`. The first retry failed the same way, for the same reason.

**Fix:** Ran `sudo -i` alone, confirmed the `root@fedora` prompt, then pasted the rest:

```bash
export LFS=/mnt/lfs
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}
for i in bin lib sbin; do
  ln -sv usr/$i $LFS/$i
done
mkdir -pv $LFS/lib64
chown -v lfs $LFS/{usr{,/*},var,etc,tools,lib64}
```

Then re-ran `cp -rv usr/include $LFS/usr`.

**Lesson:** Never paste commands after `sudo -i` in the same block. Open the root shell first, verify the prompt, then paste.

---

### Problem 6: Commands run from the wrong directory

Recurring early mistake, with several variations:

| Command | Error | Cause |
|---|---|---|
| `../configure ...` (Binutils) | `bash: ../configure: No such file or directory`, `real 0m0.001s` | Created `build/` in `/home/lfs` instead of inside the extracted source |
| `make mrproper` | `No rule to make target 'mrproper'` | Still in the GCC build directory; also revealed the GCC cleanup and `limits.h` step had been skipped |
| `cd linux-7.1.8` | `No such file or directory` | Tarball not yet extracted |
| `patch -Np1 -i ../glibc-fhs-1.patch` | Prompted `File to patch:` | Not inside `glibc-2.44` |
| `rm -v man3/crypt*` | `No such file or directory` | At `/`, not in `man-pages-6.18` |
| `tar -xf ../meson-1.12.0.tar.gz` | `Cannot open: No such file or directory` | Already in `/sources`, so `../` pointed at `/` |

**Fix pattern:** `cd /sources` → `tar -xf <package>` → `cd <package-dir>` → `pwd` to verify → follow the book.

---

### Problem 7: Dirty source trees (M4 build failure)

**Error** (Chapter 8 M4):

```
In file included from m4.c:24:
../lib/getopt.h:89:10: fatal error: getopt-cdefs.h: No such file or directory
   89 | #include <getopt-cdefs.h>
      |          ^~~~~~~~~~~~~~~~
compilation terminated.
make[2]: *** [Makefile:2577: m4.o] Error 1
```

**Cause:** Source folders from Chapters 5–7 had never been deleted. Re-extracting a tarball over an existing folder overwrites the source but keeps stale build artifacts (including a cross-compile configuration from Chapter 6), which confuses the new build.

`ls /sources` showed **about 40 leftover extracted directories**, including `gcc-16.2.0`, `glibc-2.44`, `Python-3.14.7`, `perl-5.44.0`, `tar-1.35`, `texinfo-7.3`, and `util-linux-2.42.2`.

**Fix:**

```bash
find /sources -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
```

Deletes only directories, one level deep, leaving tarballs and patches. M4 was then rebuilt from a fresh extract.

**Lesson:** `/sources` should only ever hold one extracted folder at a time. `rm -rf` each package's directory right after installing it.

---

### Problem 8: Pkgconf / Meson confusion

**Symptom:**

```
python3: can't open file '/sources/meson-1.12.0/build/../meson-1.12.0/meson.py': [Errno 2] No such file or directory
```

**Cause:** Pkgconf's instructions unpack Meson inside the Pkgconf source tree to break a circular dependency. These were run inside the `meson-1.12.0` directory instead. At first I misdiagnosed this as a Meson install procedure and gave the pip-based Meson install steps out of order.

**Fix:** Removed the stray Meson directory and redid Pkgconf from inside `pkgconf-3.0.5`:

```bash
tar -xf pkgconf-3.0.5.tar.xz && cd pkgconf-3.0.5
tar -xf ../meson-1.12.0.tar.gz
mkdir build && cd build
python3 ../meson-1.12.0/meson.py setup --prefix=/usr --buildtype=release ..
ninja && ninja install
```

**Follow-up:** Because Meson was pip-installed early, the later Meson section may need `--force-reinstall --no-deps` to install against the final Python.

---

### Problem 9: Vim test suite hung

**Command:**

```bash
su tester -c "TERM=xterm-256color LANG=en_US.UTF-8 make -j1 test" &> vim-test.log
```

**Symptom:** Terminal went silent (expected, since output goes to the log), but progress stopped at:

```
03:14 Executing Test_terminal_paste_register()
```

Ctrl+C in the chroot had no effect.

**Diagnosis** from the host:

```
$ ps -ef | grep -E 'make|vim' | grep -v grep
101  1928765  716510  0 20:03 ?  00:00:00 make -j1 test
101  1928769 1928765  0 20:03 ?  00:00:00 make test
...
101  1934803 1934802  0 20:07 ?  00:00:00 ../vim -f -u util/unix.vim ... test_terminal.vim
```

All processes showed 0 CPU time, confirming a hang. UID `101` is the chroot's `tester` user, which doesn't exist on Fedora.

**Fix:**

```bash
sudo pkill -9 -u 101
```

Then installed Vim normally. The Vim suite isn't critical, and terminal tests are known to stall in a chroot.

---

### Problem 10: Hardware clock set to local time

**Discovered while** reviewing 9.5:

```
$ timedatectl | grep "RTC in local TZ"
Warning: The system is configured to read the RTC time in the local time zone.
...
          RTC in local TZ: yes
```

**Cause:** Leftover from the old Windows dual boot. Windows keeps the hardware clock in local time; Linux expects UTC.

**First attempt failed:**

```
$ sudo timedatectl set-local-rtc 0
Failed to set local RTC: Access denied
```

No SELinux denial (`ausearch` returned `<no matches>`), and `/etc/adjtime` had the correct label (`adjtime_t`).

**Workaround:** wrote the clock directly with `hwclock`, which bypasses `timedated`:

```bash
sudo hwclock --systohc --utc
```

`/etc/adjtime` was updated, but `timedatectl` still showed the cached setting. Next step: confirm the last line of `/etc/adjtime` reads `UTC` and restart `systemd-timedated`.

**LFS side:** no `/etc/adjtime` created, so LFS assumes UTC. Both systems must agree, or the clock will be off by 3–4 hours (Atlantic Time) every time I switch between them.

> **To verify:** final state of Fedora's RTC setting wasn't confirmed in this log.

---

### Problem 11: ACL test failure

**Output:**

```
# TOTAL: 16
# PASS:  13
# XFAIL: 2
# FAIL:  1
```

**Assessment:** The book documents one expected failure (`test/cp.test`), because Coreutils isn't yet built with ACL support at that point. Check with `grep '^FAIL' test-suite.log` before installing.

---

### Problem 12: Unmounting before reboot ("target is busy")

```
umount: /mnt/lfs: target is busy.
```

```
$ fuser -vm /mnt/lfs
/mnt/lfs:   root      kernel mount /run/media/ferguson/lfs
            ferguson  9729 ..c..  bash
            root      533064 ..c.. sudo
```

**Cause:** Another terminal's working directory was inside `/mnt/lfs`, and KDE had separately auto-mounted the partition at `/run/media/ferguson/lfs`.

**Resolution:** The virtual filesystems were already unmounted, which is the part that matters. A normal reboot unmounts the rest cleanly.

---

### Minor issues

- **Binutils output mismatch:** an initial `ls $LFS/tools/bin` returned `No such file or directory`, then succeeded on the next check. Verified with `--version` and a full tool listing; root cause unknown.
- **`make & make install`** (single `&`) briefly used instead of `&&`, which backgrounds the first command. Harmless here because the build was already done, but `&&` is required going forward.
- **Groff placeholder:** `PAGE=<paper_size> ./configure` → `bash: paper_size: No such file or directory`. Angle-bracket placeholders must be replaced entirely.
- **Line wrap in pasted commands:** `make -j` and `1` appeared on separate lines in a pasted test command. Had that been a real line break, it would have run `make -j` with no limit, which the book explicitly warns causes system instability.

---

## Final System Configuration

| Item | Value |
|---|---|
| Kernel | 7.1.8, built-in NVMe/ext4/EFI stub, no initramfs |
| Init | systemd 261.2 |
| C library | Glibc 2.44 |
| Compiler | GCC 16.2.0 |
| Root FS | ext4 on `nvme1n1p1`, 100 GB |
| Locale | `en_CA.UTF-8` (console falls back to `C.UTF-8`) |
| Timezone | America/Halifax |
| Network | systemd-networkd, DHCP on `en*` (wired only) |
| DNS | systemd-resolved |
| Clock | UTC |
| Password hashing | YESCRYPT |
| Bootloader | Fedora's GRUB, custom entry |
| Backup | Post-Chapter 7 temp-tools tarball at `/home/ferguson/` |

---

## Lessons Learned

1. **Verify state, don't assume it.** The biggest problem (missing directory layout) failed silently and surfaced three sections later. A quick `ls -la $LFS` after Chapter 4.2 would have caught it immediately.
2. **Never paste commands after `sudo -i` in one block.** The password prompt eats the following lines.
3. **Always check `echo $LFS` before running anything as root.** If it's empty, paths like `$LFS/usr` resolve to the host's `/usr`. The `chown` in Chapter 7.2 would have handed Fedora's system directories to the `lfs` user.
4. **One package directory at a time.** Clean up immediately after each install.
5. **`pwd` before running anything with a relative path.** Most early errors were directory mistakes, not build problems.
6. **Built-in beats modular without an initramfs.** Root-filesystem drivers must be `=y`.
7. **Use UUIDs and PARTUUIDs.** NVMe device names aren't stable across boots.
8. **Read failing tests before panicking.** Most failures here were documented as expected.
9. **Hung processes in a chroot can be killed from the host by UID.**
10. **Document as you go.** Much of this log was reconstructed after the fact.

---

## Next Steps

1. **Networking:** the laptop needs Wi-Fi. Identify the chip (`lspci -k | grep -A3 -i network` on Fedora), then build from BLFS: `iwd` or `wpa_supplicant`, the matching kernel driver, and firmware. Use the retained kernel source in `/usr/src/linux-7.1.8` (no `make mrproper`).
2. **SSH:** OpenSSH from BLFS.
3. **DNS:** build Unbound, disable systemd-resolved, point `/etc/resolv.conf` at `127.0.0.1`.
4. **Security hardening:** kernel hardening options, firewall (nftables), SSH configuration, auditing listening services.
5. **Clean up the host:** remove the `lfs` build user (`sudo userdel -r lfs && sudo groupdel lfs`); optionally restore `/etc/bash.bashrc` if it was moved (it doesn't exist on Fedora).
6. **Confirm the RTC fix** on Fedora (`timedatectl` should show `RTC in local TZ: no`).
7. **Publish:** portfolio writeup on curtisferguson.ca and a GitHub repo with these notes and the kernel `.config`.
