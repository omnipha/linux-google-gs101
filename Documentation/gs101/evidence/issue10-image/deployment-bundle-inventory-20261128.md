# Issue #10: Deployment Bundle Inventory & Operational Tooling (2026-11-28)

**Date**: 2026-11-28  
**Scope**: Full component inventory of the consolidated preparation bundle, operational script mapping across post-recovery runbook phases, and verification gates for Issue #10.  
**Consolidated Archive**:
- **Host Path**: `/tmp/opencode/gs101/artifacts/gs101-prep-bundle-20261128.tar.gz` (5.2 MB)
- **SHA256**: `88563cccf570bf0781445056178d2aea01f4d6d1f4ddfb8525ae414014ca289f`
- **Integrity**: Verified with `tar -tzf` and `sha256sum -c gs101-prep-bundle-20261128.tar.gz.sha256`.

---

## 1. Complete Component Inventory

The consolidated deployment bundle contains all necessary kernel modules, binary firmware/calibration blobs, and deployment scripts required to configure and verify Google Tensor GS101 (`raven`, Pixel 6 Pro) post-recovery.

### 1.1 Out-of-Tree & Modular Kernel Drivers (10 Modules)
All kernel modules are built against Linux 7.3 (`7.3.0-rc6-gs101` without `+` suffix) and verified with vermagic:
```text
7.3.0-rc6-gs101 SMP preempt mod_unload aarch64
```

| Module | Location in Bundle | Size | Dependencies | Function |
| :--- | :--- | :--- | :--- | :--- |
| `bcmdhd.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 8,646,080 B | `cfg80211`, `rfkill` | Broadcom BCM4389 FullMAC Wi-Fi driver (Linux 7.3 port) |
| `pci-exynos.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 16,144 B | *None* | GS101 PCIe RC1 controller (`CONFIG_PCI_EXYNOS=m`) |
| `cfg80211.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 1,488,808 B | `rfkill` | Linux wireless configuration subsystem |
| `rfkill.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 49,048 B | *None* | Radio kill-switch subsystem |
| `bluetooth.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 1,509,304 B | `rfkill` | Core Bluetooth protocol stack |
| `hci_uart.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 216,592 B | `bluetooth`, `btbcm`, `btqca` | HCI UART transport driver with serdev support |
| `btbcm.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 30,976 B | `bluetooth` | Broadcom Bluetooth protocol helper |
| `btqca.ko` | `lib/modules/7.3.0-rc6-gs101/extra/` | 40,328 B | `bluetooth` | Qualcomm Bluetooth helper |
| `panfrost.ko` | `cand22/modules/` | 174,448 B | `gpu-sched` | Arm Mali-G78 Bifrost/Valhall GPU driver (`CONFIG_DRM_PANFROST=m`) |
| `gpu-sched.ko` | `cand22/modules/` | 97,128 B | *None* | DRM GPU scheduler subsystem |

### 1.2 Extracted BCM4389 Firmware & NVRAM Calibration (16 Blobs)
Extracted from Google stock Pixel 6 Pro firmware under `lib/firmware/`:
- **Wi-Fi Firmware**: `fw_bcmdhd.bin` (1,764,018 B), `fw_bcmdhd.map` (1,855,772 B)
- **Radio NVRAM Calibration**: `bcmdhd.cal` (24,530 B), `bcmdhd.cal_ROW`, `bcmdhd.cal_JPN`, `bcmdhd.cal_MMW`, `bcmdhd.cal_PROTO1.0`, `bcmdhd.cal_PROTO1.1`
- **Country Locale Matrix (CLM)**: `bcmdhd_clm.blob` (16,260 B), `bcmdhd_clm.blob_ROW`, `bcmdhd_clm.blob_JPN`, `bcmdhd_clm.blob_MMW`
- **Config Descriptors**: `google_wifi_firmware_config_info.pb` (513 B)
- **Bluetooth Patchram Firmware**: `brcm/BCM.hcd` (474,858 B), `brcm/BTFW_B.hcd`, `brcm/BTFW_D.hcd`

### 1.3 Versioned Operational Scripts (Repository & Bundle)
Permanently versioned in repository under [Documentation/gs101/tests/](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/):
- [install-wlan.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-wlan.sh): Sideloads 8 WLAN/BT modules and 16 firmware blobs, runs `depmod -a`, and executes controlled probe sequence `pci-exynos -> rfkill -> cfg80211 -> bcmdhd -> bluetooth -> hci_uart`.
- [unload-wlan.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/unload-wlan.sh): Reverses module insertion in strict dependency order: `hci_uart -> btqca -> btbcm -> bluetooth -> bcmdhd -> cfg80211 -> rfkill -> pci-exynos`.
- [install-gpu.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-gpu.sh): Sideloads `gpu-sched.ko` and `panfrost.ko` to `/lib/modules/7.3.0-rc6-gs101/extra/`, executes `depmod -a`, loads via `modprobe panfrost`, and writes `/etc/modules-load.d/panfrost.conf` for reboot persistence.
- [unload-gpu.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/unload-gpu.sh): Cleans `/etc/modules-load.d/panfrost.conf` and unloads `panfrost` and `gpu_sched`.
- [install-apps.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/install-apps.sh): Configures persistent default route (`172.16.42.2 dev usb0`) and DNS (`1.1.1.1` in `systemd-resolved`), and installs minimal application set (`foot`, `lxterminal`, `pcmanfm`, `galculator`, `gnome-calculator`) with offline local depot fallback.
- [verify-recovery.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/verify-recovery.sh): Host-side acceptance audit gathering system telemetry and emitting JSON evidence. Exits with code `0` only when all checks evaluate to `PASS` or expected `INFO` (`FAIL == 0`).

---

## 2. Runbook Phase Execution Mapping

| Phase | Purpose | Script / Action | Target Verification Output |
| :--- | :--- | :--- | :--- |
| **Phase 1** | USB CDC-NCM Host Setup | `sudo ip addr add 172.16.42.2/24 dev enx*` | SSH responds on `user@172.16.42.1` |
| **Phase 2** | Live Panfrost Safe Test | `insmod /tmp/gpu-sched.ko && insmod /tmp/panfrost.ko` | `/dev/dri/renderD128` exists, zero kernel oops/panic |
| **Phase 3** | Consolidated Flash | `/tmp/opencode/gs101/flash-cand23.sh` | Flashes `cand22` `boot_a` + `cand23` `vendor_boot_a` |
| **Phase 4.1** | Boot Verification | `uname -a; cat /proc/cmdline` | `7.3.0-rc6-gs101` (no `+`), `console=tty0`, `simpledrm` |
| **Phase 4.2** | Persistent GPU Loading | `Documentation/gs101/tests/install-gpu.sh` | `modprobe panfrost` clean, `/etc/modules-load.d/panfrost.conf` created |
| **Phase 4.3** | Phoc Acceleration | `WLR_RENDERER=gles2` override in `phosh.service.d` | Phoc log: Mali-G78 renderer, `grim /tmp/phosh-gles2.png` captured |
| **Phase 4.4** | WLAN & BT Staging | `Documentation/gs101/tests/install-wlan.sh` | PCIe L0 link up, `wlan0` created, `/sys/class/bluetooth/hci0` registered |
| **Phase 5.1** | Post-Reboot Persistence | Cold reboot check | `/dev/dri/renderD128` auto-loaded, `eglinfo` confirms Mali-G78 |
| **Phase 5.2** | Application Deployment | `Documentation/gs101/tests/install-apps.sh` | Default route via `172.16.42.2`, DNS `1.1.1.1`, 5 apps registered in `apk` |
| **Phase 6** | Consolidated Acceptance | `Documentation/gs101/tests/verify-recovery.sh` | Emits `/tmp/opencode/gs101/evidence/verify-recovery-<ts>.json` (`FAIL == 0`) |

---

## 3. Repository Verification Gates

To prevent conflating independent operational layers, all testing follows the strict repository separation principle:
```text
Flash != Boot != Display != Touch != GPU != Apps
```

1. **Flash Gate**: Bootloader successfully writes partitions and fastboot status is OK.
2. **Boot Gate**: Kernel boots to user space and USB CDC-NCM brings up SSH within 90 seconds.
3. **Display Gate**: `simpledrm` scans `/dev/fb0` and console output is visible on the panel without backlight driver dependency.
4. **Touch Gate**: Samsung S6SY792 probes via `vendor_ramdisk00` without vermagic rejection, correctly reporting multi-touch events on `/dev/input/event1` with zero ghost contacts.
5. **GPU Gate**: Panfrost initializes Mali-G78 without probe hang; hardware rendering confirmed via `eglinfo -B` (not llvmpipe).
6. **Apps Gate**: Minimal application set installed and visible in Phosh drawer, launchable via touch.
7. **Acceptance Gate**: [verify-recovery.sh](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/tests/verify-recovery.sh) reports `FAIL == 0`.
