# Issue #10: Kernel Configuration (.config) Symbol Audit

**Date**: 2026-11-28  
**Kernel Tree**: Linux 7.3.0-rc6-gs101+ (main branch)  
**Config Baseline**: `.config` (Candidate 20 / Modular Panfrost baseline)  
**Scope**: Verification of Bluetooth (Issue #8), GPU Panfrost (Issue #11), Display/Backlight, Input/Touch (Issue #7), Device Tree Overlays, and PMIC Regulators.  
**Policy**: Read-only audit; zero `.config` modifications in this run.

---

## 1. Symbol Audit Matrix

| Kernel Config Symbol | Line in `.config` | Current Value | Required Functionality | Assessment & Status |
| :--- | :--- | :--- | :--- | :--- |
| `CONFIG_BT` | 1615 | `=m` | Core Bluetooth subsystem (L2CAP, SCO, HCI socket layer) | **OK**: Built as module (`bluetooth.ko`) |
| `CONFIG_BT_BCM` | 1632 | `=m` | Broadcom Bluetooth core protocol engine & `.hcd` firmware loader | **OK**: Built as module (`btbcm.ko`) |
| `CONFIG_BT_HCIUART` | 1643 | `=m` | UART HCI transport protocol driver (`hci_uart.ko`) | **OK**: Built as module |
| `CONFIG_BT_HCIUART_SERDEV` | 1644 | `=y` | Serdev slave device support in `hci_uart` (binds DT `bluetooth` child) | **OK**: Enabled in `hci_uart.ko` |
| `CONFIG_BT_HCIUART_H4` | 1645 | `=y` | UART (H4) serial protocol standard framing | **OK**: Enabled |
| `CONFIG_BT_HCIUART_BCM` | 1652 | `=y` | Broadcom-specific UART protocol extensions & baudrate negotiation | **OK**: Enabled |
| `CONFIG_SERIAL_DEV_BUS` | 2806 | `=y` | Serial Device Bus (serdev) core subsystem in Linux | **OK**: Built-in (`vmlinux`) |
| `CONFIG_SERIAL_DEV_CTRL_TTYPORT` | 2807 | `=y` | Serdev controller driver for TTY serial ports (`samsung,exynos850-uart`) | **OK**: Built-in (`vmlinux`) |
| `CONFIG_BT_LE` | 1621 | *Not set* (`# is not set`) | Bluetooth Low Energy (BLE) protocol profiles and GATT support | **GAP (Documented)**: See Section 2 analysis |
| `CONFIG_DRM_PANFROST` | 4287 | `=m` | Arm Mali G78 GPU driver (cand20 modularization to prevent probe panic) | **OK**: Built as module (`panfrost.ko`) |
| `CONFIG_BACKLIGHT_CLASS_DEVICE` | 4395 | `=y` | Generic Linux backlight sysfs interface (`/sys/class/backlight`) | **OK**: Built-in (`vmlinux`) |
| `CONFIG_BACKLIGHT_PWM` | 4401 | `=y` | Generic PWM-driven backlight driver | **OK**: Built-in (`vmlinux`) |
| `CONFIG_INPUT_EVDEV` | 2500 | `=m` | Evdev input event interface (`/dev/input/event*`) for touch & buttons | **OK**: Built as module (`evdev.ko`) |
| `CONFIG_INPUT_UINPUT` | 2669 | `=y` | Userspace input injector (`/dev/uinput`) for on-screen keyboard (Squeekboard) | **OK**: Built-in (`vmlinux`) |
| `CONFIG_OF_OVERLAY` | 2003 | `=y` | Core Device Tree overlay application engine | **OK**: Built-in (`vmlinux`) |
| `CONFIG_OF_DYNAMIC` | 1998 | `=y` | Dynamic device tree modification support | **OK**: Built-in (`vmlinux`) |
| `CONFIG_OF_RESOLVE` | 2002 | `=y` | Device tree phandle resolution engine for overlays | **OK**: Built-in (`vmlinux`) |
| `CONFIG_OF_FPGA_REGION` | 6959 | `=m` | OF overlay region driver | **OK**: Built as module |
| `CONFIG_OF_CONFIGFS` | 2005 | *Not set* (`# is not set`) | Userspace runtime DTBO loader via `/sys/kernel/config/device-tree/` | **Minor Gap**: Overlays applied by bootloader |
| `CONFIG_MFD_SEC_ACPM` | 3591 | `=y` | Multi-Function Device driver for Samsung ACPM / S2MPG10 PMIC | **OK**: Built-in (`vmlinux`) |
| `CONFIG_REGULATOR_S2MPS11` | 3734 | `=y` | PMIC regulator driver managing Samsung S2MPG10 power rails | **OK**: Built-in (`vmlinux`) |
| `CONFIG_EXYNOS_ACPM_PROTOCOL` | 1978 | `=y` | ACPM IPC communication protocol with power management firmware | **OK**: Built-in (`vmlinux`) |

---

## 2. In-Depth Gap Analysis

### 2.1 Bluetooth Low Energy: `CONFIG_BT_LE` (`# CONFIG_BT_LE is not set`)
- **Serdev Driver Probe Impact**:
  - The serial device bus (`serial_dev_bus`) and Broadcom HCI driver (`hci_uart` / `btbcm`) operate at the HCI transport layer.
  - The driver probe, UART line discipline attachment, AC/DC clocking, GPIO power toggle (`gpp16-2`), and `.hcd` firmware RAM patch download use standard HCI vendor commands (HCI H4 packet types `0x01` Command, `0x04` Event).
  - **Verdict**: Serdev probe and hardware initialization **do NOT require `CONFIG_BT_LE`**. Basic BR/EDR classic Bluetooth operates normally.
- **Userspace / Profile Impact**:
  - Without `CONFIG_BT_LE=y`, BlueZ cannot register LE advertising, LE scanning, or GATT clients/servers. Userspace attempts to pair BLE devices (keyboards, trackers, BLE audio) will fail with `EOPNOTSUPP`.
  - **Action Item**: Maintain as a documented gap for the current bring-up phase; enable `CONFIG_BT_LE=y` in a subsequent batch config update once hardware probe is verified on-device.

### 2.2 Userspace Overlay Loading: `CONFIG_OF_CONFIGFS` (`# is not set`)
- Kernel supports in-kernel dynamic overlay application (`CONFIG_OF_OVERLAY=y`, `CONFIG_OF_DYNAMIC=y`).
- Because `CONFIG_OF_CONFIGFS` is disabled, userspace cannot dynamically inject `.dtbo` files at runtime via `/sys/kernel/config/device-tree/overlays/`.
- All overlays on Pixel 6 Pro are merged statically or by the bootloader (`libufdt`). This is completely adequate for current operation.

### 2.3 PMIC Regulators for PCIe & Wireless Subsystems
- **DTS Mapping**:
  - `vdd085_pcie1`: Mapped to PMIC rail `ldo28m` / `buck28m` under `s2mpg10-regulator`.
  - `vdd18_pcie1`: Mapped to PMIC rail `ldo32m` under `s2mpg10-regulator`.
  - `wl_reg_on`: Controlled via standard GPIO `gpp14-2` (`pinctrl_peric0`).
- **Driver Architecture**:
  - Samsung GS101 uses the S2MPG10 ACPM PMIC. In the Linux kernel driver tree, `drivers/regulator/s2mps11.c` contains full unified support for `samsung,s2mpg10-regulator` enabled under `CONFIG_REGULATOR_S2MPS11=y`.
  - Communication with the PMIC is mediated via `CONFIG_MFD_SEC_ACPM=y` and `CONFIG_EXYNOS_ACPM_PROTOCOL=y`.
  - **Verdict**: All required voltage regulators for the PCIe RC1 and BCM4389 power tree are fully supported and compiled into the kernel.
