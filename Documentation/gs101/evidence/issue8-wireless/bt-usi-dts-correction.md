# Issue #8 Wireless: Bluetooth APM USI1/UART16 DTS Correction & DTB Evidence

**Date**: 2026-11-28  
**Scope**: Correction of Bluetooth UART16 hardware description to include the parent Exynos USI (Universal Serial Interface) controller, rebuild of raven/oriole DTBs, and generation of `cand21` `vendor_boot.img`.

---

## 1. Root Cause Analysis: Missing USI Parent Controller

In commit `69bff1b43`, `serial_16: serial@175b0000` was introduced as a standalone node. While syntactically valid in device tree, this was architecturally insufficient for Samsung Exynos hardware:

1. **Hardware USI Architecture**:
   On Google Tensor GS101, UART16 (APM USI1 domain) is not an independent peripheral; it resides inside an Exynos USI IP block (`usi@175b00c0`).
2. **Mainline Driver Division**:
   - `drivers/soc/samsung/exynos-usi.c` (`compatible = "samsung,exynos850-usi"` / `"google,gs101-usi"`): Controls the USI wrapper, clears `USI_CON_RESET` in `USI_CON` (`0x175b00c4`), un-gates clocks (`USI_OPTION_CLKREQ_ON`), and programs the software configuration register `SW_CONF` to `USI_MODE_UART` (`0x1`) via the APM system controller (`sysreg_apm`).
   - `drivers/tty/serial/samsung_tty.c` (`compatible = "google,gs101-uart"`): Implements the UART serial driver but contains **zero** USI or SYSREG register handling.
3. **Stock DT Verification**:
   Inspection of `/tmp/opencode/gs101/stock/stock-base.dts` shows:
   - `serial@175B0000` defines `samsung,usi-phandle = <&syscon_174204e0>` and `samsung,usi-offset = <0x04>`.
   - In mainline, `sysreg_apm: syscon@17420000` covers this space, meaning offset `0x174204e0 - 0x17420000 + 0x04 = 0x04e4`.
   - Without `usi@175b00c0` setting mode `0x1` at `sysreg_apm 0x04e4` and releasing USI reset, the hardware UART block remains held in reset and unclocked.

---

## 2. DTS Implementation Changes

### 2.1 SoC Baseline ([arch/arm64/boot/dts/exynos/google/gs101.dtsi](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101.dtsi#L1873-L1899))
Defined `usi16: usi@175b00c0` as parent container with child `serial_16: serial@175b0000`:
```dts
		usi16: usi@175b00c0 {
			compatible = "google,gs101-usi", "samsung,exynos850-usi";
			reg = <0x175b00c0 0x20>;
			ranges;
			#address-cells = <1>;
			#size-cells = <1>;
			clocks = <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_PCLK>,
				 <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_IPCLK>;
			clock-names = "pclk", "ipclk";
			samsung,sysreg = <&sysreg_apm 0x04e4>;
			samsung,mode = <USI_MODE_UART>;
			status = "disabled";

			serial_16: serial@175b0000 {
				compatible = "google,gs101-uart";
				reg = <0x175b0000 0xc0>;
				clocks = <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_PCLK>,
					 <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_IPCLK>;
				clock-names = "uart", "clk_uart_baud0";
				interrupts = <GIC_SPI 69 IRQ_TYPE_LEVEL_HIGH 0>;
				pinctrl-0 = <&uart16_bus>;
				pinctrl-names = "default";
				samsung,uart-fifosize = <256>;
				status = "disabled";
			};
		};
```

### 2.2 Board Enablement ([arch/arm64/boot/dts/exynos/google/gs101-raven.dts](file:///home/gregor/github_repos/linux-google-gs101/arch/arm64/boot/dts/exynos/google/gs101-raven.dts#L155-L177))
Enabled `usi16` with clock-request pinning and activated `serial_16` with the Broadcom Bluetooth child:
```dts
&usi16 {
	samsung,mode = <USI_MODE_UART>;
	samsung,clkreq-on;
	status = "okay";
};

&serial_16 {
	status = "okay";
	pinctrl-0 = <&uart16_bus>;
	pinctrl-names = "default";

	bluetooth {
		compatible = "brcm,bcm4349-bt", "brcm,bcm43438-bt";
		shutdown-gpios = <&gpp16 2 GPIO_ACTIVE_HIGH>;
		device-wakeup-gpios = <&gpp14 3 GPIO_ACTIVE_HIGH>;
		host-wakeup-gpios = <&gpa6 6 GPIO_ACTIVE_HIGH>;
		interrupt-parent = <&gpa6>;
		interrupts = <6 IRQ_TYPE_EDGE_RISING>;
		interrupt-names = "host-wakeup";
		max-speed = <3000000>;
	};
};
```

---

## 3. DTC Decompilation Evidence: Old vs. New

### Old Baseline (`commit 69bff1b43`)
Standalone node without USI controller:
```dts
		serial@175b0000 {
			compatible = "samsung,exynos850-uart";
			reg = <0x175b0000 0x100>;
			clocks = <0x75 0x16 0x75 0x15 0x75 0x2f>;
			clock-names = "uart", "clk_uart_baud0", "clk_uart_baud1";
			interrupts = <0x00 0x45 0x04 0x00>;
			pinctrl-0 = <0x76>;
			pinctrl-names = "default";
			status = "okay";
			phandle = <0x146>;

			bluetooth { ... };
		};
```

### New Corrected Baseline (`gs101-raven.dtb`)
Full hierarchical USI wrapper + UART device:
```dts
		usi@175b00c0 {
			compatible = "google,gs101-usi", "samsung,exynos850-usi";
			reg = <0x175b00c0 0x20>;
			ranges;
			#address-cells = <0x01>;
			#size-cells = <0x01>;
			clocks = <0x75 0x16 0x75 0x15>;
			clock-names = "pclk", "ipclk";
			samsung,sysreg = <0x73 0x4e4>;
			samsung,mode = <0x01>;
			status = "okay";
			samsung,clkreq-on;
			phandle = <0x146>;

			serial@175b0000 {
				compatible = "google,gs101-uart";
				reg = <0x175b0000 0xc0>;
				clocks = <0x75 0x16 0x75 0x15>;
				clock-names = "uart", "clk_uart_baud0";
				interrupts = <0x00 0x45 0x04 0x00>;
				pinctrl-0 = <0x76>;
				pinctrl-names = "default";
				samsung,uart-fifosize = <0x100>;
				status = "okay";
				phandle = <0x147>;

				bluetooth {
					compatible = "brcm,bcm4349-bt", "brcm,bcm43438-bt";
					shutdown-gpios = <0x77 0x02 0x00>;
					device-wakeup-gpios = <0x78 0x03 0x00>;
					host-wakeup-gpios = <0x79 0x06 0x00>;
					interrupt-parent = <0x79>;
					interrupts = <0x06 0x01>;
					interrupt-names = "host-wakeup";
					max-speed = <0x2dc6c0>;
				};
			};
		};
```

---

## 4. `cand21` Vendor Boot Artifact Verification

In Android boot header v4, the kernel DTB is unpacked and loaded by the bootloader from the `vendor_boot` partition (`dtb` region), **not** from `boot.img`. The previous `cand18` `vendor_boot.img` carried an older DTB without `serial_16`.

To ensure the corrected DTB reaches the live kernel upon recovery, `cand21` `vendor_boot.img` was generated:
1. **DTB Region Construction**: Built with `/tmp/opencode/gs101/build_dtb_region.py`:
   - Exact stock geometry: `536,176` bytes total.
   - FDT #0: `totalsize = 268095`
   - FDT #1: `totalsize = 268081`
2. **Reverse Verification (`unpack_bootimg`)**:
   - Both FDT #0 and FDT #1 verified to contain `usi@175b00c0` (`status = "okay"`), `serial@175b0000` (`status = "okay"`), and child `bluetooth`.
   - `vendor_ramdisk00`: Byte-identical to `cand18` (`23,905,675` bytes, sha256: `e8198d3bc7162d2dbe84a145e4f19c011c0bf007ffaf25df3e6ec131628629de`).
   - `vendor_cmdline`: Byte-identical to `cand18`.
3. **Artifact Hash**:
   - Path: `/tmp/opencode/gs101/cand21/vendor_boot.img`
   - Size: `24,449,024` bytes
   - SHA-256: `43d5252a016b6b77fa4ed6164da097e84c0c2ce23eb9a9cd640e00209599daf4`
