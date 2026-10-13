# Meridian

A Linux system built from source with Linux From Scratch 13.1 (systemd) and BLFS, running on bare metal alongside Fedora.

- Built from source: cross-toolchain, ~80 base packages, custom kernel
- Wi-Fi, audio, and graphics firmware brought up by hand
- Linux-PAM with systemd-logind sessions
- Key-only SSH, default-deny firewall (IPv4 and IPv6), configuration tracked in Git

Full write-up, including 22 documented problems and how they were solved: [docs/build-log.md](docs/build-log.md)

Configs: [configs/](configs/)
