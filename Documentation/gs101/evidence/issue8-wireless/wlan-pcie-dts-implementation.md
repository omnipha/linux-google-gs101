# GS101 WLAN PCIe Root Complex 1 (`pcie_1`) Devicetree Implementation

**Date**: 2026-11-28  
**Scope**: Issue #8 Wireless offline preparation (steer26)  
**Targets**: `arch/arm64/boot/dts/exynos/google/gs101.dtsi`, `arch/arm64/boot/dts/exynos/google/gs101-overlay-anchors.dtsi`, `arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi`, `arch/arm64/boot/dts/exynos/google/gs101-raven.dts`, `arch/arm64/boot/dts/exynos/google/gs101-oriole.dts`  
**Status**: Verified host-side build and DTC decompile; live testing blocked by physical device hardware recovery.

---

## 1. Executive Summary

As part of the offline engineering groundwork for Issue #8 (Broadcom BCM4389 Wi-Fi 6E / Bluetooth 5.2), the PCIe Root Complex 1 (`pcie_1`, base address `0x14520000`) has been fully implemented in the GS101 mainline device tree.

Previously, PCIe RC1 was represented solely by an inert placeholder anchor (`pcie_1: anchor-pcie_1 { };`) in [gs101-overlay-anchors.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-overlay-anchors.dtsi). This stub has now been replaced with the complete Synopsys DesignWare Core (DWC) PCIe host controller topology derived from the stock Pixel 6 Pro (`raven`) factory device tree extraction and the architecture defined in [wlan-pcie-plan-and-firmware-deployment.md](file:///home/gregor/github_repos/linux-google-gs101/Documentation/gs101/evidence/issue8-wireless/wlan-pcie-plan-and-firmware-deployment.md).

---

## 2. Devicetree Topology & Architecture

### 2.1 Address Translation Expansion (`soc@0` ranges)
In [arch/arm64/boot/dts/exynos/google/gs101.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101.dtsi), the `soc: soc@0` bus previously mapped only up to `0x40000000`:
```dts
ranges = <0x0 0x0 0x0 0x40000000>;
```
The PCIe RC1 outbound config window (`0x60ffe000`) and outbound memory window (`0x60000000..0x60feffff`) reside in the `0x60000000` address range (and PCIe RC0 in `0x40000000`). The range mapping has been expanded to:
```dts
ranges = <0x0 0x0 0x0 0x80000000>;
```
This transparently maps all 32-bit child physical addresses `0x00000000` through `0x7fffffff` 1:1 to parent physical addresses `0x00000000 0x00000000` through `0x00000000 0x7fffffff`.

### 2.2 Controller Node Definition (`gs101.dtsi`)
The controller node is positioned in address-sorted order within the HSI2 domain:
```dts
pcie_1: pcie@14520000 {
	compatible = "google,gs101-pcie",
		     "samsung,exynos-pcie-rc",
		     "samsung,exynos5433-pcie",
		     "snps,dw-pcie";
	reg = <0x14520000 0x2000>,
	      <0x14550000 0x2000>,
	      <0x14420000 0x2000>,
	      <0x14800000 0x301000>,
	      <0x14540000 0x1000>,
	      <0x60ffe000 0x2000>,
	      <0x14500000 0x1000>;
	reg-names = "elbi", "phy", "sysreg", "dbi", "pcs", "config", "ia";
	#address-cells = <3>;
	#size-cells = <2>;
	device_type = "pci";
	bus-range = <0x00 0xff>;
	ranges = <0x82000000 0x0 0x60000000 0x60000000 0x0 0xff0000>;
	num-lanes = <1>;
	max-link-speed = <2>;

	interrupts = <GIC_SPI 509 IRQ_TYPE_LEVEL_HIGH 0>;
	interrupt-names = "msi";
	#interrupt-cells = <1>;
	interrupt-map-mask = <0 0 0 0>;
	interrupt-map = <0 0 0 0 &gic GIC_SPI 509 IRQ_TYPE_LEVEL_HIGH 0>;

	clocks = <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_DBI_ACLK_UG>,
		 <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_MSTR_ACLK_UG>,
		 <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_SLV_ACLK_UG>,
		 <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_I_DRIVER_APB_CLK>,
		 <&cmu_hsi2 CLK_GOUT_HSI2_PCIE_GEN4_1_PCIE_003_PHY_REFCLK_IN>,
		 <&cmu_hsi2 CLK_MOUT_HSI2_PCIE_USER>;
	clock-names = "pcie", "pcie_bus", "slv", "apb", "ref", "user";

	samsung,sysreg = <&sysreg_hsi2>;
	samsung,pmu-syscon = <&pmu_system_controller>;
	samsung,syscon-phandle = <&pmu_system_controller>;
	pmu-offset = <0x3ec4>;
	ch-num = <1>;

	status = "disabled";
};
```

### 2.3 Board Integration & Endpoint Configuration (`gs101-raven.dts`)
In [arch/arm64/boot/dts/exynos/google/gs101-raven.dts](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-raven.dts), `&pcie_1` is enabled with board-level pinctrl, regulators, and the BCM4389 WLAN endpoint child node:
```dts
&pcie_1 {
	pinctrl-0 = <&pcie1_clkreq &pcie1_perst>;
	pinctrl-names = "default";
	reset-gpios = <&gph2 0 GPIO_ACTIVE_LOW>;
	vdd085-supply = <&ldo17m>;
	vdd18-supply = <&ldo19m>;
	vdd10-supply = <&ldo17m>;
	vreg1-supply = <&ldo17m>;
	vreg2-supply = <&ldo19m>;
	status = "okay";

	wlan: wifi@0,0 {
		compatible = "android,bcmdhd_wlan", "pci14e4,4389";
		reg = <0x0000 0 0 0 0>;
		wl_reg_on = <&gpp14 2 GPIO_ACTIVE_HIGH>;
		wl_host_wake = <&gpa7 0 GPIO_ACTIVE_HIGH>;
		wl_dev_wake = <&gph2 5 GPIO_ACTIVE_HIGH>;
		ch-num = <1>;
		status = "okay";
	};
};
```

### 2.4 Regulator Labeling (`gs101-pixel-common.dtsi`)
Explicit labels were added to the PCIe PMIC LDO regulators in [gs101-pixel-common.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-pixel-common.dtsi):
- `ldo16m: ldo16m` (`vdd085_pcie0`)
- `ldo17m: ldo17m` (`vdd085_pcie1`)
- `ldo18m: ldo18m` (`vdd18_pcie0`)
- `ldo19m: ldo19m` (`vdd18_pcie1`)

### 2.5 Power Domain Analysis
Neither the factory base device tree (`stock-base.dts`) nor the vendor overlay fragments 12 and 26 declare a `power-domains = <...>` property for `pcie@14520000`. On Exynos 9845 / GS101, power gating is coordinated by the SoC PMU via `pmu-offset = <0x3ec4>` in conjunction with CMU clock gating. Mainline GS101 does not currently expose HSI2 generic power domain (genpd) nodes.

---

## 3. Driver Binding Analysis: `pci-exynos.c` vs `snps,dw-pcie`

A comparative analysis of existing upstream DWC drivers highlights the expectations and constraints for GS101 PCIe:

| Feature / Requirement | Upstream `pci-exynos.c` (`samsung,exynos5433-pcie`) | Upstream `pcie-designware-plat.c` (`snps,dw-pcie`) | GS101 Mainline DTS Implementation |
|---|---|---|---|
| **Compatible string match** | `"samsung,exynos5433-pcie"` | `"snps,dw-pcie"` | Matches both, plus `"google,gs101-pcie"` and `"samsung,exynos-pcie-rc"` |
| **MMIO Register Blocks** | Requires `"elbi"`, `"dbi"`, `"config"` | Generic DWC: fetches `"dbi"`, `"config"`, optional `"elbi"`, `"atu"` | Exposes all 7 blocks (`elbi`, `phy`, `sysreg`, `dbi`, `pcs`, `config`, `ia`) |
| **Clock Management** | Uses `devm_clk_bulk_get_all_enabled()` to acquire and enable all declared clocks | DWC core clock helpers (looks for standard `"dbi"`, `"core"` if `REQ_RES` set) | Provides 6 clocks with compatible names: `"pcie"`, `"pcie_bus"`, `"slv"`, `"apb"`, `"ref"`, `"user"` |
| **PHY Integration** | Requires mandatory `devm_of_phy_get()` (fails probe if PHY node missing) | Does not sequence PHY natively; expects pre-initialized PHY or wrapper | Compatible with both direct wrapper MMIO (`reg-names = "phy"`) and future generic PHY |
| **Regulators** | Mandates `supplies[0] = "vdd18"` and `supplies[1] = "vdd10"` | No generic regulator handling (relies on DT regulator consumers) | Provides both `vdd18`/`vdd10` (mapped to `ldo19m`/`ldo17m`) and `vdd085`/`vreg1`/`vreg2` |
| **ELBI Register Map** | Targets Exynos5433 ELBI offsets (e.g. `PCIE_CORE_RESET = 0x1c`, `PCIE_ELBI_SLV_AWMISC = 0x11c`) | Does not access vendor ELBI registers | GS101 ELBI revision is `0x984500` (Exynos 9845 / GS101); register offsets differ from 5433 |

> [!WARNING]
> **No Functional Link Claims Without Live Hardware**:  
> While the devicetree node topology matches all standard Synopsys DWC and Exynos conventions, the upstream `pci-exynos.c` driver contains Exynos5433-specific ELBI bitfields and mandatory PHY phandle checks. A dedicated GS101 PCIe host driver backend (or adapted DWC glue driver) will be evaluated once the physical device is accessible.

---

## 4. Verification & Build Evidence

### 4.1 Compilation
Both the target `raven` (Pixel 6 Pro) and companion `oriole` (Pixel 6) device tree blobs compile cleanly without errors or warnings:
```bash
make ARCH=arm64 LLVM=1 exynos/google/gs101-raven.dtb exynos/google/gs101-oriole.dtb
```

### 4.2 DTC Decompilation Verification
Decompiling `arch/arm64/boot/dts/exynos/google/gs101-raven.dtb` confirms:
1. **Node Presence & State**:
   ```dts
   pcie@14520000 {
       compatible = "google,gs101-pcie", "samsung,exynos-pcie-rc", "samsung,exynos5433-pcie", "snps,dw-pcie";
       reg = <0x14520000 0x2000 0x14550000 0x2000 0x14420000 0x2000 0x14800000 0x301000 0x14540000 0x1000 0x60ffe000 0x2000 0x14500000 0x1000>;
       reg-names = "elbi", "phy", "sysreg", "dbi", "pcs", "config", "ia";
       status = "okay";
       pinctrl-0 = <0x6f 0x70>;
       reset-gpios = <0x71 0x00 0x01>;
       vdd085-supply = <0x72>;
       vdd18-supply = <0x73>;
       ...
       wifi@0,0 {
           compatible = "android,bcmdhd_wlan", "pci14e4,4389";
           reg = <0x00 0x00 0x00 0x00 0x00>;
           wl_reg_on = <0x74 0x02 0x00>;
           wl_host_wake = <0x75 0x00 0x00>;
           wl_dev_wake = <0x71 0x05 0x00>;
           status = "okay";
       };
   };
   ```
2. **Symbol Table Generation (`/__symbols__`)**:
   ```dts
   /__symbols__ {
       pcie_1 = "/soc@0/pcie@14520000";
       wlan = "/soc@0/pcie@14520000/wifi@0,0";
   };
   ```
   Overlay fragments targeting `pcie_1` (such as stock vendor overlays applied by the bootloader) will resolve directly to `/soc@0/pcie@14520000`.

3. **Oriole Inactive State**:
   In `gs101-oriole.dtb`, `pcie@14520000` remains correctly disabled (`status = "disabled"`).

---

## 5. Next Steps for Device-Gated Runs

Once physical recovery of the device is completed by the operator:
1. Deploy `boot_a` / `vendor_boot` carrying the updated device tree.
2. Monitor dmesg for PCIe host controller probe logs (`dmesg | grep -i pci`).
3. Validate link training to Gen2 x1 and verify BCM4389 discovery via `lspci -nnvv`.
