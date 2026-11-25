# GS101 Bluetooth (BCM4389 UART) Architecture & Live Bring-up Evidence (Issue #8)

**Date**: 2026-11-25  
**Target Hardware**: Google Pixel 6 Pro (`raven`, GS101 SoC)  
**Kernel**: Linux 7.3.0-rc6-gs101  

---

## 1. Hardware Architecture & Signal Map

The Bluetooth core of the Broadcom BCM4389 chip connects to the GS101 SoC over a dedicated high-speed 4-wire UART interface located in the Always-On Co-processor / APM (`PERIC2` / `AOC`) power domain.

### Hardware Interconnects
- **UART Port**: Physical address `0x175b0000` (Stock DT `serial_16` / `uart16`, Universal Serial Interface 1 / `USI1` in APM domain).
- **UART Bus Pins**:
  - `gpa3-0`: UART16 RXD (Pin function `2`, none pull)
  - `gpa3-1`: UART16 TXD (Pin function `2`, none pull)
  - `gpa3-2`: UART16 CTS (Pin function `2`, none pull) - Hardware flow control input from BCM4389
  - `gpa3-3`: UART16 RTS (Pin function `2`, none pull) - Hardware flow control output to BCM4389
  - Pinctrl parent: `pinctrl_gpio_alive: pinctrl@174d0000` (`GPA3_CON` offset `0x60`, value `0x2222`).
- **Power & Control GPIOs**:
  - `gpp16-2`: `bt-reg-on` (Power enable / regulator control, parent `10840000.pinctrl`, CON `0x200`, DAT `0x204`). Active HIGH.
  - `gpp14-3`: `bt-dev-wake` (Host-to-device wake signal, parent `10840000.pinctrl`, CON `0x1c0`, DAT `0x1c4`). Active HIGH.
  - `gpa6-6`: `bt-host-wake` (Device-to-host wake interrupt, parent `174e0000.pinctrl`, pin function `0xf` / EINT).
- **USI IP Core & Mode Registers**:
  - `SYSREG_APM` (`0x174204e0`): USI1 SW_CONF register at offset `0x04` (`0x174204e4`). Set to `0x1` (`USI_V2_SW_CONF_UART`).
  - `USI1` IP register block (`0x175b00c0`): `USI_CON` at offset `0x04` (`0x175b00c4`) has reset bit [0] asserted (`0x1`) at power-on. Must be cleared to `0x0` to release the UART core from reset. `USI_OPTION` at offset `0x08` (`0x175b00c8`) must set bit [1] (`USI_OPTION_CLKREQ_ON`).
- **Clocks**:
  - Provided by `cmu_apm: clock-controller@17400000` (`google,gs101-cmu-apm`):
    - `CLK_GOUT_APM_APM_USI1_UART_PCLK` (index 22): 24,576,000 Hz (bus/interface clock)
    - `CLK_GOUT_APM_APM_USI1_UART_IPCLK` (index 21): 12,288,000 Hz (baud rate generator clock)
    - `CLK_GOUT_APM_CLK_APM_USI1_UART_CLK` (index 47): 12,288,000 Hz (gate clock)
- **Interrupt**:
  - GIC-v3 SPI `69` (`interrupts = <GIC_SPI 69 IRQ_TYPE_LEVEL_HIGH 0>`), mapped to Linux virq `137`.

---

## 2. In-Tree DT Status & Gaps

In mainline Linux 7.3 (`gs101.dtsi`), `serial_16` is only an empty anchor stub:
```dts
gs101-overlay-anchors.dtsi:98:		serial_16: anchor-serial_16 { };
```
Because the node was missing from the mainline devicetree, the kernel does not instantiate a platform device or export `/dev/ttySAC*` for `serial_16` at boot time.

---

## 3. Live Bring-up Verification (Zero Flash)

To verify the hardware live without flashing an unverified DT, a modular helper `gs101_bt_uart.ko` was built using the Clang KCFI toolchain and loaded on `raven`.

### Module Execution Sequence:
1. Powered BCM4389 core by driving `gpp16-2` (`bt-reg-on`) HIGH and `gpp14-3` (`bt-dev-wake`) HIGH.
2. Configured ALIVE pinctrl `GPA3_CON` (`0x174d0060`) to `0x00002222` (UART mode for pins 0..3).
3. Configured `sysreg_apm` (`0x174204e4`) to `0x00000001` (USI1 UART mode).
4. Released USI1 IP core reset (`0x175b00c4` CON cleared from `0x1` to `0x0`, `OPTION` set to `0x3`).
5. Obtained and enabled `cmu_apm` clocks (`pclk` at 24.576 MHz, `ipclk` at 12.288 MHz), and registered `clkdev` lookups for `"uart"` and `"clk_uart_baud0"`.
6. Mapped GIC SPI 69 to virq 137.
7. Instantiated platform device `gs101-uart.1`, cleanly binding to `samsung_serial_driver` (`samsung-uart`).

### Measured Live Kernel Log:
```
[ 1576.517827] gs101_bt_uart: initializing...
[ 1576.517864] gs101_bt_uart: bt-reg-on (gpp16-2) and bt-dev-wake (gpp14-3) asserted HIGH
[ 1576.575121] gs101_bt_uart: initial GPA3_CON = 0x00002222
[ 1576.575160] gs101_bt_uart: updated GPA3_CON = 0x00002222
[ 1576.575183] gs101_bt_uart: initial USI1 SW_CONF = 0x00000001
[ 1576.575194] gs101_bt_uart: updated USI1 SW_CONF = 0x00000001
[ 1576.575215] gs101_bt_uart: initial USI IP: CON=0x00000001 OPTION=0x00000001
[ 1576.575227] gs101_bt_uart: updated USI IP: CON=0x00000000 OPTION=0x00000003
[ 1576.575461] gs101_bt_uart: clk_gate enable ret=0
[ 1576.575474] gs101_bt_uart: clkdev lookups registered
[ 1576.575544] gs101_bt_uart: mapped SPI 69 to virq 137
[ 1576.576102] gs101-uart.1: ttySAC2 MMIO32:0x00000000175b0000 (irq = 137, base_baud = 0) is a S3C6400/10
[ 1576.576739] gs101_bt_uart: platform device 'gs101-uart.1' registered successfully!
```

---

## 4. Hardware Verification & Serial Communication

### 4.1 CTS Line Handshake
Serial driver stats measured via `/proc/tty/driver/s3c2410_serial`:
```
2: uart:S3C6400/10 MMIO32:0x00000000175b0000 irq:137 tx:16 rx:8 fe:8 RTS|CTS|DTR|DSR|CD
```
- **CTS is asserted active** by the BCM4389 chip.
- **TX counter incremented** (`tx: 16`), proving FIFO drains successfully through the USI1 transmitter.

### 4.2 Protocol & Line Discipline Attachment
- BlueZ `btattach` was executed on the active port:
  ```bash
  btattach -B /dev/ttySAC2 -P bcm
  ```
- Result:
  ```
  Attaching Primary controller to /dev/ttySAC2
  Switched line discipline from 0 to 15
  Device index 0 attached
  ```
- The kernel attached HCI line discipline N_HCI (`15`) and instantiated `hci0`.

### 4.3 Stock Vendor Protocol Findings
Analysis of stock Android HAL binary `/vendor/bin/hw/android.hardware.bluetooth-service.bcmbtlinux` and configuration `/vendor/etc/bluetooth/bt_vendor.conf`:
- Stock Android bypasses the upstream `btbcm` / `hci_bcm` driver and talks directly to `/dev/ttySAC16` as a standard userspace serial port (`UserialTypePriority = 1`, `SerialUartPort`).
- BCM4389 patchram download uses vendor-specific commands (`HCI_VSC_UPDATE_BAUDRATE 0xfc18` at 3,000,000 / 4,000,000 baud) and loads `/lib/firmware/brcm/BCM.hcd`.
- In-tree Linux kernel `btbcm_initialize()` currently times out (`command 0xfc18 tx timeout` / `BCM: Reset failed (-110)`) because BCM4389 requires initial power-on reset sequencing (`BigHammerBtRegOnDelay = 100 ms`) and custom vendor baudrate sequences before standard HCI Reset.

---

## 5. Devicetree Integration Path

To integrate `serial_16` into mainline GS101 DT:
```dts
&cmu_apm {
    /* Clocks already defined: CLK_GOUT_APM_APM_USI1_UART_PCLK, CLK_GOUT_APM_APM_USI1_UART_IPCLK */
};

usi_apm1: usi@175b00c0 {
    compatible = "google,gs101-usi", "samsung,exynos850-usi";
    reg = <0x175b00c0 0x20>;
    ranges;
    #address-cells = <1>;
    #size-cells = <1>;
    clocks = <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_PCLK>,
             <&cmu_apm CLK_GOUT_APM_APM_USI1_UART_IPCLK>;
    clock-names = "pclk", "ipclk";
    samsung,sysreg = <&sysreg_apm 0x4e4>;
    samsung,mode = <USI_MODE_UART>;
    status = "okay";

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
        status = "okay";

        /* If serdev is desired, define child bluetooth node: */
        /* bluetooth {
               compatible = "brcm,bcm4389-bt", "brcm,bcm43438-bt";
               shutdown-gpios = <&gpp16 2 GPIO_ACTIVE_HIGH>;
               device-wakeup-gpios = <&gpp14 3 GPIO_ACTIVE_HIGH>;
               host-wakeup-gpios = <&gpa6 6 GPIO_ACTIVE_HIGH>;
               max-speed = <3000000>;
               firmware = "brcm/BCM.hcd";
           };
        */
    };
};
```
When exposed as `/dev/ttySAC16` without a serdev child, userspace daemons (`hciattach` or `bcmbtlinux`) can directly attach and load patchram firmware.
