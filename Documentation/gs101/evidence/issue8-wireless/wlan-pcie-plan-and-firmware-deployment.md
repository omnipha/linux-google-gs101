# Issue #8 Wireless: WLAN PCIe (BCM4389) Implementation Plan & Firmware Deployment Recipe

**Date**: 2026-11-28  
**SoC**: Google Tensor GS101 (`raven` / Pixel 6 Pro)  
**Kernel**: Linux 7.3.0-rc6-gs101+  
**Status**: Host-side planning & DTS preparation complete; live testing gated by device physical recovery.

---

## 1. WLAN PCIe Root Complex 1 (`pcie_1`) Implementation Plan

In Google Tensor GS101, the Broadcom BCM4389 combo chipset connects its Wi-Fi 6E endpoint via PCIe Gen2 x1 to PCIe Root Complex 1 (`pcie_1`).

### 1.1 Current DTS Baseline
- **Anchor Node**: In [arch/arm64/boot/dts/exynos/google/gs101-overlay-anchors.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-overlay-anchors.dtsi), PCIe RC1 exists as an empty placeholder stub:
  ```dts
  pcie_1: anchor-pcie_1 { };
  ```
- **Pinctrl Definitions**: Already defined in [arch/arm64/boot/dts/exynos/google/gs101-pinctrl.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-pinctrl.dtsi):
  - `pcie1_clkreq`: Pin `gph2-1`, function `GS101_PIN_FUNC_2`, pull-up, drive 10 mA.
  - `pcie1_perst`: Pin `gph2-0`, function `GS101_PIN_FUNC_OUTPUT`, drive 10 mA.
- **Power Regulators**: Mapped in [arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi):
  - `vdd085_pcie1`: PMIC LDO / Buck rail (`0.85V`).
  - `vdd18_pcie1`: PMIC LDO rail (`1.8V`).
- **Out-of-band Control GPIOs**:
  - `gpp14-2`: `wl_reg_on` (WLAN power enable, active-high).
  - `gpa6-4` (or similar APM wake): `wl_host_wake` (WLAN PCIe device-to-host wake interrupt).

### 1.2 Required DWC Controller Register Blocks (MMIO)
Implementation of the full DWC (DesignWare Core) PCIe host controller requires the following register ranges:
1. **ELBI (Exynos Local Bus Interface)**:
   - Base address: `0x14520000` (domain `HSI2`).
   - Controls top-level wrapper configuration, app resets, power states, and link status reporting.
2. **DBI (DesignWare Inbound/Outbound Configuration & Control)**:
   - Base address: typically `0x14500000` or offset from controller base.
   - Standard Synopsys DesignWare PCIe registers (link speed, width, BAR configuration, ATU outbound address translation).
3. **PHY / PCS / PMA (Physical Layer & Sub-layer)**:
   - Base address: associated Samsung PCIe Gen4 PHY register block.
   - Configures analog PLL, clock buffers, impedance calibration, and lane equalization.

### 1.3 Clocks & Resets (`cmu_hsi2`)
Clock management for PCIe RC1 is governed by the `cmu_hsi2` clock controller (`0x14400000`):
- `CLK_MOUT_HSI2_PCIE_USER` (idx 3): Mux clock feeding PCIe domain.
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_PHY_REFCLK_IN` (idx 5): 100 MHz reference clock for PCIe RC1 PHY.
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_DBI_ACLK_UG` (idx 19): DBI interface bus clock.
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_MSTR_ACLK_UG` (idx 20): Master AXI bus clock (DMA transactions).
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_SLV_ACLK_UG` (idx 21): Slave AXI bus clock.
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_I_DRIVER_APB_CLK` (idx 22): Controller register APB clock.
- `CLK_GOUT_HSI2_PCIE_GEN4_1_PCS_PMA_PHY_UDBG_I_APB_PCLK` (idx 27), `CLK_GOUT_HSI2_PCIE_GEN4_1_PCS_PMA_PIPE_PAL_PCIE_I_APB_PCLK` (idx 28), `CLK_GOUT_HSI2_PCIE_GEN4_1_PCS_PMA_PCIEPHY210X2_QCH_I_APB_PCLK` (idx 29): PHY and PCS APB management clocks.
- `CLK_GOUT_HSI2_PCIE_IA_GEN4A_1_I_CLK` (idx 30): Interconnect adapter clock.
- **Resets**: Managed via `sysreg_hsi2` (`0x14420000`).

### 1.4 Open Engineering Questions for Subsequent Device-Gated Runs
1. **PCIe Host Controller Driver Architecture**:
   - Upstream `drivers/pci/controller/dwc/pci-exynos.c` currently supports only legacy `"samsung,exynos5433-pcie"`.
   - GS101 requires either a modern Exynos DWC backend or extending `pci-exynos.c` to support the GS101 ELBI register layout and Gen4 PHY wrapper.
2. **PHY Driver Integration**:
   - Verification of whether a standalone `drivers/phy/samsung/phy-exynos-pcie.c` exists or whether PHY sequencing is handled directly within the PCIe controller driver.
3. **Link Training & Power-On Sequencing**:
   - Order of assertions between `vdd085_pcie1`, `vdd18_pcie1`, `wl_reg_on` (`gpp14-2`), and `pcie1_perst` (`gph2-0`).
   - Proper link negotiation to Gen2 x1 (downclocked from Gen4 capability of controller).
4. **Endpoint Enumeration**:
   - Verification of BCM4389 enumeration (`0x4389` / `0x4441` / `0x4442`) under `lspci` once link training completes.

---

## 2. Firmware Deployment Recipe

During rootfs generation or live image deployment, the 16 extracted BCM4389 firmware files stored locally outside the git repository must be placed into the target filesystem.

### 2.1 Source Directory & Permissions
- **Host Source Path**:
  `/home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/`
- Host directory permissions: `0700` (`rwx------`)
- Host file permissions: `0600` (`rw-------`)

### 2.2 Target Deployment Paths & Permissions
All deployed firmware files on the target rootfs must have owner `root:root` and file mode `0644` (`rw-r--r--`):

#### A. Bluetooth Firmware (`/lib/firmware/brcm/`)
Create target directory `/lib/firmware/brcm/`:
```bash
sudo mkdir -p /lib/firmware/brcm
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/brcm/BCM.hcd /lib/firmware/brcm/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/brcm/BTFW_B.hcd /lib/firmware/brcm/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/brcm/BTFW_D.hcd /lib/firmware/brcm/
sudo chmod 0644 /lib/firmware/brcm/*.hcd
sudo chown root:root /lib/firmware/brcm/*.hcd
```
*Note on Bluetooth*: Upstream kernel `btbcm` automatically looks up `/lib/firmware/brcm/BCM.hcd` or board-specific `.hcd` upon probe of the serdev `serial@175b0000` node.

#### B. Wi-Fi Firmware (`/lib/firmware/` or `/lib/firmware/bcmdhd/`)
Copy core operational binaries and calibration blobs to `/lib/firmware/`:
```bash
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/fw_bcmdhd.bin /lib/firmware/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/bcmdhd.cal /lib/firmware/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/bcmdhd_clm.blob /lib/firmware/
# Regional calibration variants:
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/bcmdhd.cal_* /lib/firmware/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/bcmdhd_clm.blob_* /lib/firmware/
sudo cp /home/gregor/phone-second-life-data/mb010/firmware/bcm4389-extracted/firmware/google_wifi_firmware_config_info.pb /lib/firmware/
sudo chmod 0644 /lib/firmware/fw_bcmdhd* /lib/firmware/bcmdhd* /lib/firmware/google_wifi*
sudo chown root:root /lib/firmware/fw_bcmdhd* /lib/firmware/bcmdhd* /lib/firmware/google_wifi*
```

### 2.3 Upstream `brcmfmac` vs. `bcmdhd` Driver Path Warning

> [!WARNING]
> **Upstream `brcmfmac` Incompatibility**:
> - Upstream kernel `drivers/net/wireless/broadcom/brcm80211/brcmfmac/` has **zero** support for BCM4389 (`0x4389`).
> - Furthermore, `brcmfmac` expects Broadcom FullMAC format (`brcmfmac4389-pcie.bin`, `brcmfmac4389-pcie.clm_blob`, `brcmfmac4389-pcie.txt`).
> - The extracted vendor firmware (`fw_bcmdhd.bin`, `bcmdhd.cal`, `bcmdhd_clm.blob`) is compiled specifically for Broadcom's proprietary out-of-tree `bcmdhd` Dongle Host Driver (`android,bcmdhd_wlan`).
> - Consequently, functional Wi-Fi requires either:
>   1. Backporting/porting the open Broadcom DHD (`bcmdhd4389`) driver to Linux 7.3+, OR
>   2. Adding BCM4389 chip ID and firmware translation support to upstream `brcmfmac` (if compatible microcode exists).
> - This remains an open engineering track to be tackled once PCIe host controller bring-up enables link training and endpoint discovery.
