# Issue #10: Application Minimal-Set & Network Persistence Status (Steer 11)

## 1. Network Infrastructure & Baseline Status
- **Host-NAT Configuration**: Host NAT active on `172.16.42.0/24` out `wlo1` via `iptables MASQUERADE`, `ip_forward=1`. Host DNS forwarding `53/udp -> 1.1.1.1`.
- **Target Network State**: Prior to cand19 flash, device default route was active via `172.16.42.2` and global DNS resolving via `systemd-resolved` (`127.0.0.53`). Ping to `8.8.8.8` confirmed operational.

## 2. Minimal Application Target Set (postmarketOS aarch64)
- **Terminal**: `lxterminal` (installed in prior session; persistence across cold reboot pending verification); `foot` available as lightweight fallback.
- **File Manager**: `pcmanfm` / `float` candidate evaluation targeted.
- **Calculator**: `gnome-calculator` / `galculator` / `apcalc` evaluation targeted.

## 3. Dependency & Execution Block
- Live package persistence verification (`sudo reboot` without network intervention) and minimal app installation via `apk` are temporarily blocked pending device reboot into the restored `cand14` baseline.
- Automated rollback listener is armed and ready on host to restore `cand14` `boot_a` as soon as fastboot is entered via operator Power + VolDown.
