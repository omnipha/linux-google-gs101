# GS101 Wi-Fi (BCM4389 PCIe) In-Tree Audit & Porting Analysis (Issue #8)

**Date**: 2026-11-25  
**Target Hardware**: Google Pixel 6 Pro (`raven`, GS101 SoC)  
**Kernel**: Linux 7.3.0-rc6-gs101  

---

## 1. Hardware Architecture Overview

The Wi-Fi subsystem on Google Pixel 6 Pro (`raven`) uses a Broadcom **BCM4389** Wi-Fi 6E (802.11ax, 2.4 GHz, 5 GHz, 6 GHz) chip connected to the GS101 SoC via **PCIe Gen2 x1** (Root Complex 1, `pcie_1`).

### Stock Hardware Interconnects
From stock device tree (`stock-base.dts` and `stock-raven.dtbo`):
- **PCIe RC1 Node**: `pcie@14520000` (label `pcie_1`)
  - Compatible: `"samsung,exynos-pcie-rc"`
  - Register Base: `0x14520000`
  - Number of Lanes: 1 (`num-lanes = <1>`)
  - Max Link Speed: Gen2 (`max-link-speed = <2>`)
  - Power Supplies: `vreg1-supply`, `vreg2-supply` (PMIC LDOs)
  - Control GPIO: `gpp14-2` (`wl_reg_on` / `pcie,wlan-gpio`)
- **Firmware Files Required**:
  - `fw_bcmdhd.bin` (Firmware microcode)
  - `bcmdhd.cal` (Calibration / NVRAM parameters)
  - `bcmdhd_clm.blob` (Country Locale Matrix regulatory blob)

---

## 2. In-Tree Driver Audit (Linux 7.3)

### 2.1 In-Tree `brcmfmac` Support
An audit of `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` and `drivers/net/wireless/broadcom/brcm80211/include/brcm_hw_ids.h` was conducted:
- `brcmfmac` supports various Broadcom FullMAC SDIO, USB, and PCIe devices (e.g. BCM4350, BCM4356, BCM4366, BCM4371).
- **Result**: `brcmfmac` has **zero** support for BCM4389. The BCM4389 PCI Device ID (`0x4441` / `0x4442`) is completely absent from the upstream kernel.
- In addition, BCM4389 requires proprietary Broadcom DHD (Dongle Host Driver) protocol extensions and custom firmware message passing that are not implemented in the open-source `brcmfmac` driver.

### 2.2 In-Tree PCIe Root Complex Driver Support
An audit of `drivers/pci/controller/dwc/` was conducted for GS101 / Exynos PCIe:
- Mainline Linux only contains `pcie-exynos.c` supporting older Exynos5433 / Exynos5440 platforms (`"samsung,exynos5433-pcie"`).
- In mainline `gs101.dtsi`, the PCIe controllers are unmapped placeholders:
  ```dts
  anchor-pcie_0 { };
  anchor-pcie_1 { };
  ```
- Neither the GS101 PCIe RC1 controller (`0x14520000`) nor the PCIe PHY driver is currently upstreamed or enabled in Linux 7.3.

---

## 3. Stock Driver & Module Audit

Stock vendor kernel modules were inspected from the device's `vendor_dlkm_a` partition:
- Module: `bcmdhd4389.ko`
- Kernel Vermagic: `6.1.162-android14-11-gd7a0a08e0e15-ab16261946`
- Arch: `aarch64`
- **Result**: The stock vendor binary module cannot be loaded directly onto the running Linux 7.3 kernel due to incompatible kernel version, ABI, and KCFI integrity structures (`.gnu.linkonce.this_module section size must match`).

---

## 4. Implementation Roadmap for Issue #8

To achieve operational Wi-Fi on raven:

1. **Phase 1: GS101 PCIe Controller Bring-up**:
   - Port the Exynos/GS101 PCIe Root Complex driver (`drivers/pci/controller/dwc/pcie-exynos-gs101.c` or update `pcie-designware-host.c`) to map `0x14520000`.
   - Implement PCIe PHY power sequencing and clocks (`CLK_GOUT_HSI1_...`).
   - Add DT bindings for `pcie@14520000` with `num-lanes = <1>` and `pcie,wlan-gpio = <&gpp14 2 GPIO_ACTIVE_HIGH>`.
   - Verify link training (`Link Up, Gen2 x1`) with BCM4389 endpoint enumeration (`lspci` shows `Broadcom Inc. BCM4389`).

2. **Phase 2: Broadcom DHD Driver Port (`bcmdhd4389`)**:
   - Port the open-source/vendor Broadcom DHD driver source tree for BCM4389 to build against Linux 7.3.
   - Adapt API calls for Linux 7.3 networking and wireless subsystems (`cfg80211`, `net_device_ops`).
   - Configure firmware loading from `/lib/firmware/` (`fw_bcmdhd.bin`, `bcmdhd.cal`, `bcmdhd_clm.blob`).

3. **Status**:
   - Firmware binaries: Extracted and verified on filesystem (`/lib/firmware/`).
   - Driver status: Blocked pending PCIe controller bring-up and out-of-tree DHD porting (Issue #8 work item, not WAIT_OWNER).
