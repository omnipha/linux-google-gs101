# Issue #8 Wireless: Bluetooth DTS Clean Build Evidence & Decompilation Verification

**Date**: 2026-11-28  
**Commit Baseline**: `90f869dc6` (origin/main)  
**Target Hardware**: Google Pixel 6 Pro (`raven`) & Pixel 6 (`oriole`)  
**Architecture**: ARM64 (`aarch64`)  
**Compiler**: LLVM / Clang (in-tree DTC v1.7.0)

---

## 1. Clean DTB Build Execution

To prove the validity of the DTS changes introduced in commits `69bff1b43` and verified in `90f869dc6`, all existing DTB binaries were deleted and rebuilt from clean source using:
```bash
rm -f arch/arm64/boot/dts/exynos/google/gs101-raven.dtb arch/arm64/boot/dts/exynos/google/gs101-oriole.dtb
make ARCH=arm64 LLVM=1 exynos/google/gs101-raven.dtb exynos/google/gs101-oriole.dtb
```

### 1.1 Compiler Output
```text
  DTC     arch/arm64/boot/dts/exynos/google/gs101-raven.dtb
  DTC     arch/arm64/boot/dts/exynos/google/gs101-oriole.dtb
```
Build completed with exit code `0` and zero warnings or errors.

### 1.2 Binary File Attributes & Cryptographic Hashes

| Target DTB | File Size (Bytes) | Build Timestamp | SHA-256 Hash |
| :--- | :--- | :--- | :--- |
| `gs101-raven.dtb` | 94,527 | 2026-11-28 03:36:41.696108895 +0100 | `c033ca1bc9bbb98ea4030c6932655fabce65a50346212d3b0981ae0b41869e84` |
| `gs101-oriole.dtb` | 64,007 | 2026-11-28 03:36:41.750109086 +0100 | `abb5048136d419cc50e609f520a3cde567dc685265a46e391e385467ae2135ab` |

> [!NOTE]
> As per repository policy, these binary DTB build artifacts are strictly excluded from git version control.

---

## 2. Decompiled DTS Evidence (`dtc -I dtb -O dts`)

### 2.1 Google Pixel 6 Pro (`raven`): Active Serdev Bluetooth Node
Decompiled from `gs101-raven.dtb`:
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
```

#### Property Breakdown:
- **UART Controller**: `serial@175b0000` (APM USI1 domain, physical address `0x175b0000`, size `0x100`).
- **Status**: `status = "okay"`.
- **Interrupt**: GIC-v3 SPI 69 (`0x45` hex), level high.
- **Clocks**: Clock provider `cmu_apm` (`phandle 0x75`):
  - Bus clock: index `22` (`0x16` hex = `CLK_GOUT_APM_APM_USI1_UART_PCLK`)
  - Baud clock 0: index `21` (`0x15` hex = `CLK_GOUT_APM_APM_USI1_UART_IPCLK`)
  - Baud clock 1: index `47` (`0x2f` hex = `CLK_GOUT_APM_CLK_APM_USI1_UART_CLK`)
- **Pinctrl**: Group `uart16_bus` (`phandle 0x76`).
- **Bluetooth Serdev Child**:
  - `compatible`: `"brcm,bcm4349-bt"`, `"brcm,bcm43438-bt"`.
  - `shutdown-gpios`: Pin `gpp16-2` (`phandle 0x77`, pin 2, active high = `0x00`).
  - `device-wakeup-gpios`: Pin `gpp14-3` (`phandle 0x78`, pin 3, active high = `0x00`).
  - `host-wakeup-gpios`: Pin `gpa6-6` (`phandle 0x79`, pin 6, active high = `0x00`).
  - `interrupt-parent`: Bank `gpa6` (`phandle 0x79`).
  - `interrupts`: Pin 6, IRQ type `EDGE_RISING` (`0x01`).
  - `interrupt-names`: `"host-wakeup"`.
  - `max-speed`: `3000000` baud (`0x2dc6c0` hex = 3.0 MBaud).

---

### 2.2 Google Pixel 6 (`oriole`): Base Inactive Node
Decompiled from `gs101-oriole.dtb`:
```dts
		serial@175b0000 {
			compatible = "samsung,exynos850-uart";
			reg = <0x175b0000 0x100>;
			clocks = <0x75 0x16 0x75 0x15 0x75 0x2f>;
			clock-names = "uart", "clk_uart_baud0", "clk_uart_baud1";
			interrupts = <0x00 0x45 0x04 0x00>;
			pinctrl-0 = <0x76>;
			pinctrl-names = "default";
			status = "disabled";
		};
```
The node is inherited from `gs101.dtsi` with default `status = "disabled"`, demonstrating clean separation between SoC baseline and board-specific enablements.
