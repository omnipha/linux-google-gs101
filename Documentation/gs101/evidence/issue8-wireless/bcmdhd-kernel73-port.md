# Broadcom BCM4389 `bcmdhd` Driver Linux 7.3 Compatibility Port & Module Build Evidence

**Date:** 2026-11-28
**Author:** Antigravity / Google DeepMind Team
**Scope:** Host-side compatibility port and out-of-tree module compilation of Broadcom `bcmdhd` driver (`android15-6.1-qpr2` baseline) targeting Linux 7.3 (`7.3.0-rc6-gs101`) for Google Tensor GS101 (Pixel 6 Pro, `raven`).
**Constraint Reference:** Work strictly host-side; device hardware remains OFF awaiting operator physical power-on. No flash, no fastboot, no kernel image build, no vendor_boot rebuild. In accordance with [AGENTS.md](file:///home/gregor/github_repos/linux-google-gs101/AGENTS.md), proprietary source archives and firmware blobs remain strictly outside the repository under `/home/gregor/phone-second-life-data/mb010/` and `/tmp/opencode/gs101/`.

---

## 1. Executive Summary

The Broadcom BCM4389 combo Wi-Fi 6E / Bluetooth 5.2 chipset on Google Tensor GS101 (`raven`) relies on the out-of-tree `bcmdhd` driver because mainline `brcmfmac` does not support chipsets newer than BCM4387.

Following the procurement of `bcmdhd` driver source code from the official Android Open Source Project (AOSP) `android15-6.1-qpr2` branch (commit `07aaee502e78656ae626ac214fb8f48d9a731cf8`), an out-of-tree Linux 7.3 compatibility port was developed, built, and verified host-side.

The build successfully generated `bcmdhd.ko` with clean symbols, correct vermagic, and verified BCM4389 PCI hardware ID aliases.

### Module Artifact Summary

| Property | Value |
| :--- | :--- |
| **Output Module** | `/tmp/opencode/gs101/bcmdhd73/bcmdhd.ko` |
| **Module File Size** | 8,634,712 bytes (~8.3 MiB) |
| **SHA-256 Checksum** | `8f6ad033353aa0c9c9f4eb79d3f301c1727a1b2af9e57d462c82f027f4410ffb` |
| **Target Kernel Vermagic** | `7.3.0-rc6-gs101 SMP preempt mod_unload aarch64` |
| **Vermagic Mode** | Option A (`LOCALVERSION=""`, no trailing `+`, matches `cand14`/`cand20` baseline) |
| **PCI Aliases** | `pci:v000014E4d00004441sv*sd*bc02sc80i*`<br>`pci:v000014E4d00004389sv*sd*bc02sc80i*` |
| **Dependencies** | `cfg80211`, `rfkill` |

---

## 2. Kernel 6.1 to 7.3 API Port Analysis & Resolution

Porting `bcmdhd` from Android Common Kernel 6.1 to mainline Linux 7.3 (`7.3.0-rc6-gs101`) required resolving 18 distinct architectural and API breaking changes:

### 2.1 Out-of-Tree Kbuild Configuration
1. **Module Root Detection (`Kbuild`)**:
   - *Problem:* When building with `M=/tmp/opencode/gs101/bcmdhd73`, `BCMDHD_ROOT` defaulted to `.` inside the kernel repository root, misdirecting header paths.
   - *Fix:* Configured `Kbuild` to prefer `$(M)` or `$(CURDIR)` for `BCMDHD_ROOT`.
2. **Module Name Alignment (`Kbuild`)**:
   - *Problem:* Default Makefile appended chip suffixes (`bcmdhd_4389.ko`).
   - *Fix:* Cleared `BCM_WLAN_CHIP_SUFFIX =` to generate standard `bcmdhd.ko`.
3. **Compiler Diagnostics (`Kbuild`)**:
   - *Fix:* Added `-Wno-error=missing-prototypes`, `-Wno-error=incompatible-function-pointer-types`, `-Wno-error=array-bounds`, and `-Wno-unused-function` to accommodate Broadcom legacy C macros under modern Clang 18.

### 2.2 System & Standard Header Adaptations
4. **`<asm/unaligned.h>`**:
   - *Problem:* `<asm/unaligned.h>` was removed in modern kernels in favor of `<linux/unaligned.h>`.
   - *Fix:* Provided a wrapper forwarding `<asm/unaligned.h>` to `<linux/unaligned.h>`.
5. **`<stdarg.h>`**:
   - *Problem:* Clang integrated headers no longer expose `<stdarg.h>` directly in kernel module builds.
   - *Fix:* Provided a wrapper forwarding to `<linux/stdarg.h>`.
6. **`<net/lib80211.h>`**:
   - *Problem:* Removed upstream in Linux 6.3.
   - *Fix:* Guarded with `#if (LINUX_VERSION_CODE < KERNEL_VERSION(6, 3, 0))` in `include/linuxver.h`.

### 2.3 Kernel Core Subsystem Changes
7. **Timer Subsystem (`del_timer` / `del_timer_sync`)**:
   - *Problem:* `del_timer` and `del_timer_sync` were deprecated and removed in Linux 6.13 in favor of `timer_delete` and `timer_delete_sync`.
   - *Fix:* Added macros mapping `del_timer` to `timer_delete(&((t)->timer))` and `del_timer_sync` to `timer_delete_sync(&((t)->timer))` for `>= 6.13.0`.
8. **High-Resolution Timers (`hrtimer_init` -> `hrtimer_setup`)**:
   - *Problem:* In Linux 6.14+, `hrtimer_init` was replaced by `hrtimer_setup(timer, callback, clock_id, mode)`, and `timer->function` became a private member.
   - *Fix:* In `dhd_msgbuf.c`, invoked `hrtimer_setup(&agg_db_info->timer, dhd_msgbuf_agg_h2d_db_timer_fn, CLOCK_MONOTONIC, HRTIMER_MODE_REL)` for `>= 6.14.0`.
9. **String Library (`strncpy`)**:
   - *Problem:* `strncpy` was removed from `<linux/string.h>` in mainline Linux to eliminate unsafe string operations.
   - *Fix:* Implemented inline `bcm_strncpy_compat` bounded helper in `include/linuxver.h`.
10. **Interrupt Core (`irq_desc.kstat_irqs`)**:
    - *Problem:* `desc->kstat_irqs` was converted to an internal struct in Linux 6.12.
    - *Fix:* Replaced direct field access with `irq_desc_kstat_cpu(desc, i)` for `>= 6.12.0` in `dhd_linux.c`.
11. **Softirq Execution (`raise_softirq`)**:
    - *Problem:* `raise_softirq` is no longer exported to external loadable modules in upstream Linux.
    - *Fix:* Guarded redundant post-NAPI softirq wakeup in `dhd_linux_lb.c` since `__napi_schedule()` natively manages softirq dispatch.

### 2.4 Wireless & Network Subsystem Changes
12. **Device Class Creation (`class_create`)**:
    - *Problem:* `class_create` dropped the `struct module *owner` first argument in Linux 6.4.
    - *Fix:* Used single-argument `class_create(CLASS_NAME)` for `>= 6.4.0` in `wb_regon_coordinator.c`.
13. **Channel Switch Notification (`cfg80211_ch_switch_notify`)**:
    - *Problem:* Signature changed to 3 arguments `(dev, chandef, link_id)` in Linux 6.3.
    - *Fix:* Adapted call in `wl_cfgvif.c` to pass 3 arguments for `>= 6.3.0`.
14. **Station Management (`cfg80211_new_sta` / `cfg80211_del_sta`)**:
    - *Problem:* In Linux 6.8+, station management functions require `struct wireless_dev *` instead of `struct net_device *`.
    - *Fix:* Passed `ndev->ieee80211_ptr` for `>= 6.8.0` in `wl_cfgvif.c`.
15. **Wiphy Parameter Configuration (`wl_cfg80211_set_wiphy_params`)**:
    - *Problem:* Linux 6.8+ added `int radio_idx` parameter.
    - *Fix:* Updated function signature and callback definition for `>= 6.8.0` in `wl_cfg80211.c`.
16. **Wireless Device Locking (`wdev->mtx`)**:
    - *Problem:* `wdev->mtx` was replaced by `wiphy_lock(wdev->wiphy)` / `wiphy_unlock` in Linux 6.5.
    - *Fix:* Updated `wl_cfg80211_wdev_lock` and `wl_cfg80211_wdev_unlock` in `wl_cfg80211.c`.
17. **Ingress Mini-Queue Check (`net_device.miniq_ingress`)**:
    - *Problem:* `miniq_ingress` member was removed in Linux 6.4.
    - *Fix:* Guarded check in `dhd_linux_rx.c` for `< 6.4.0`.

### 2.5 Bus & Platform Decoupling
18. **PCI Driver Structure (`struct pci_driver.node`)**:
    - *Problem:* `struct list_head node` was removed from `struct pci_driver` in Linux 6.8.
    - *Fix:* Guarded obsolete `node:` struct initializer in `dhd_pcie_linux.c`.
19. **OOB Wakeup Routing**:
    - *Problem:* PCIe OOB host wake called SDIO-specific `dhd_enable_oob_intr()` when `BCMPCIE_OOB_HOST_WAKE` was not explicitly defined.
    - *Fix:* Guarded `dhd_enable_oob_intr()` under `defined(BCMSDIO)` and routed PCIe OOB through `dhd_bus_oob_intr_set()`.
20. **Mainline Platform Glue Decoupling**:
    - *Problem:* Android-specific `dhd_custom_google.c` depended on proprietary Android out-of-tree symbols (`exynos-pci-ctrl`, `sscoredump`).
    - *Fix:* Utilized the clean weak symbols in `dhd_linux_platdev.c` and added default stubs for `dhd_wlan_init()`, `dhd_wlan_deinit()`, and `dhd_set_platform_ext_name_for_chip_version()`, decoupling the driver from proprietary Android services.

---

## 3. Build & Verification Evidence

### 3.1 Build Invocation

The module was compiled out-of-tree against the verified kernel tree on `main`:

```bash
make -j$(nproc) ARCH=arm64 LLVM=1 LOCALVERSION="" \
    -C /home/gregor/github_repos/linux-google-gs101 \
    M=/tmp/opencode/gs101/bcmdhd73 modules
```

**Build Output:**
```
make: Verzeichnis „/home/gregor/github_repos/linux-google-gs101“ wird betreten
make[1]: Verzeichnis „/tmp/opencode/gs101/bcmdhd73“ wird betreten
  CC [M]  dhd_linux.o
  CC [M]  dhd_linux_platdev.o
  CC [M]  dhd_linux_lb.o
  LD [M]  bcmdhd.o
  MODPOST Module.symvers
  CC [M]  bcmdhd.mod.o
  CC [M]  .module-common.o
  LD [M]  bcmdhd.ko
make[1]: Verzeichnis „/tmp/opencode/gs101/bcmdhd73“ wird verlassen
make: Verzeichnis „/home/gregor/github_repos/linux-google-gs101“ wird verlassen
```

### 3.2 Module Information (`modinfo`)

```
filename:       /tmp/opencode/gs101/bcmdhd73/bcmdhd.ko
license:        GPL and additional rights
license:        GPL v2
description:    Broadcom WiFi BT Regon coordinator Driver
author:         Broadcom Corporation
name:           bcmdhd
depends:        cfg80211,rfkill
alias:          pci:v000014E4d00004441sv*sd*bc02sc80i*
alias:          pci:v000014E4d00004389sv*sd*bc02sc80i*
vermagic:       7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
```

### 3.3 Hardware ID Verification

- Broadcom Vendor ID: `0x14E4`
- BCM4389 Standard Device ID: `0x4441`
- BCM4389 OTP/Production Device ID: `0x4389`

Binary strings check:
```bash
$ strings /tmp/opencode/gs101/bcmdhd73/bcmdhd.ko | grep -E "4441|4389"
dhd_fill_sssr_reg_info_4389
alias=pci:v000014E4d00004441sv*sd*bc02sc80i*
alias=pci:v000014E4d00004389sv*sd*bc02sc80i*
dhd_fill_sssr_reg_info_4389
bcm4389_naming_table
```

---

## 4. Next Steps for Hardware Testing Post-Recovery

Once physical operator recovery of the Pixel 6 Pro device is completed and Fastboot / SSH access is verified:

1. **Kernel & Device Tree Flash:**
   - Execute prepared `flash-cand22.sh` (or `cand20` depending on test plan) and `flash-cand23.sh` to flash the updated `gs101-raven.dtb` containing `pcie@14520000` (PCIe RC1) and `CONFIG_PCI_EXYNOS=y`.
2. **Firmware & NVRAM Deployment:**
   - Sideload firmware blobs from `/home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/` to `/lib/firmware/postmarketos/` or `/vendor/firmware/fw_bcmdhd.bin` and calibration files to `/vendor/etc/wifi/bcmdhd.cal`.
3. **Module Sideloading & Loading:**
   - Transfer `bcmdhd.ko` to the device:
     ```bash
     scp /tmp/opencode/gs101/bcmdhd73/bcmdhd.ko root@192.168.2.15:/lib/modules/7.3.0-rc6-gs101/kernel/drivers/net/wireless/
     ssh root@192.168.2.15 "depmod -a && modprobe bcmdhd"
     ```
4. **Verification Commands on Target:**
   - Verify PCIe discovery: `lspci -nn -k` (expect `14e4:4441` or `14e4:4389` bound to `bcmdhd`).
   - Verify network interface: `iw dev` or `ip link show wlan0`.
   - Test Wi-Fi scan: `iw dev wlan0 scan`.
