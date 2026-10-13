#!/bin/bash

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

chroot "${LFS:?}" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    PS1='(lfs chroot) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" \
    TESTSUITEFLAGS="-j$(nproc)" \
    /bin/bash --login
