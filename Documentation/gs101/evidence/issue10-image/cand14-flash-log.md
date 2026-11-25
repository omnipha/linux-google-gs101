# Issue #10: Usable Phosh Image Packaging & Candidate 14 Verification

## 1. Candidate 14 Architecture & Artifacts
- **Kernel & Driver Enhancements:**
  - `sec_ts` driver kept modular (`CONFIG_TOUCHSCREEN_SEC_TS=m`) to guarantee rapid, deterministic early boot and eliminate regulator/clock settlement race conditions observed in cand13 (`=y`).
  - Integrated in-tree hardware pinmux fallback in `sec_ts_pinctrl_configure()`:
    - Direct verification and atomic configuration of `GS101_GPP23_CON_PHYS` (`0x10c40060`) to `0x00221222` (`GS101_PIN_FUNC_2` on pins `gpp23-0..2`).
    - Standard Linux `PINCTRL_STATE_DEFAULT` / `PINCTRL_STATE_SLEEP` fallbacks.
  - Corrected DT pinctrl assignment in `gs101-pixel-common.dtsi` and `gs101-raven.dts`:
    - `&spi_touch` (`spi@10d40000`) exclusively claims `&spi11_bus` (`gpp23-0..2`) and `&spi11_cs` (`gpp23-3`).
    - `touchscreen@0` exclusively claims touch control pins (`&ts_irq &ts_reset &ap2aoc &aoc2ap_irq`), preventing pinctrl group double-request conflicts (`-EINVAL`).
  - Full MT Protocol B compliance and SPI PIO transaction safety:
    - Retained standard pointer emulation via `input_mt_report_pointer_emulation(dev, true)`.
    - Removed manual `BTN_TOOL_FINGER` overrides.
    - Preserved 6-event transfer chunking to prevent SPI FIFO overruns.
  - Packaged DTB as standard two-FDT region via `build_dtb_region.py` (536,176 B) matching Google Tensor bootloader geometry.

## 2. Artifact Hashes (Candidate 14 & Rollback Baselines)
| Image | Path | SHA-256 Hash |
| --- | --- | --- |
| **cand14 boot.img** | `/tmp/opencode/gs101/cand14/boot.img` | `84323d06a8df3b2cdcc9e05ccba802951e123d4cf2bc28ba781358f69020de36` |
| **cand14 vendor_boot.img** | `/tmp/opencode/gs101/cand14/vendor_boot.img` | `cc1e1bdb8c1e2b99324ad3eec2b60748460bb793a9460b0e149ae4b02a561052` |
| **cand14 raven-region.dtb** | `/tmp/opencode/gs101/cand14/raven-region.dtb` | `fa7180ee611a5b849319e7a8e2ae96b86bdf3b5be56fba11b1f6db9c6d7fa0e3` |
| **cand14 sec_touch.ko** | `drivers/input/touchscreen/sec_ts/sec_touch.ko` | `ecca5e38c80c4231fffcfff8ee56e985ebc25db478f01f1be48fc81952f60484` |
| **cand12 boot.img (rollback)** | `/tmp/opencode/gs101/cand12/boot.img` | `f67833f190468bccb5acfe5b3189c0c4e8203cab64aa88abf5a167613afcf2fe` |
| **cand5 vendor_boot.img (rollback)** | `/tmp/opencode/gs101/cand5/vendor_boot.img` | `97424a4dbad07269eabdca206cda885738e30c78f8f76cb3ec25cf5155465c55` |

## 3. Flash Execution & Single Flash Verification
- Execution script: `/tmp/opencode/gs101/flash-cand14.sh`
- Device rebooted to fastboot: `1B021FDEE004XV fastboot`
- Active slot: `a`
- Flashed `boot_a` (14232 KB) -> OKAY [0.507s]
- Flashed `vendor_boot_a` (25804 KB) -> OKAY [0.884s]
- Fastboot reboot issued at `2026-11-25T14:29:28+01:00`
- SSH reachability:
  - Host configured USB NCM interface.
  - SSH returned `ONLINE` within **14 seconds** (well within the mandatory 90s timeout).
  - No rollback triggered.

## 4. Boot Verification Across Two Consecutive Reboots
### Boot 1 (Initial Boot After Flash)
- Kernel: `Linux mb010 7.3.0-rc6-gs101 #14 SMP PREEMPT Wed Nov 25 14:23:01 CET 2026 aarch64`
- Hardware register `0x10C40060` (gpp23 CON): `0x00221222` (pins 0..2 configured for SPI11).
- `dmesg` probe sequence:
  ```
  [    3.537833] sec_ts spi0.0: [sec_input] sec_ts_probe
  [    3.556789] sec_ts spi0.0: [sec_input] sec_ts_pinctrl_configure: ACTIVE
  [    3.557039] sec_ts spi0.0: [sec_input] sec_ts_power: enable vdd
  [    3.558076] sec_ts spi0.0: [sec_input] sec_ts_power: enable avdd
  [    3.695247] sec_ts spi0.0: [sec_input] sec_ts_wait_for_ready_with_count: 09, 00, 10, 00, 00, 00, 00, 00 [0]
  [    3.708026] sec_ts spi0.0: [sec_input] sec_ts_fw_init: DEVICE ID: 53, 45, 37, 92, 00
  [    3.780166] sec_ts spi0.0: [sec_input] sec_ts_read_information: nTX: 18, nRX: 39, rY: 3120, rX: 1440
  [    3.789280] sec_ts spi0.0: [sec_input] sec_ts_read_information: BOOT_STATUS: 20
  [    3.805738] input: sec_touchscreen as /devices/platform/soc@0/10d400c0.usi/10d40000.spi/spi_master/spi0/spi0.0/input/input1
  [    3.805886] sec_ts spi0.0: [sec_input] sec_ts_probe: request_irq = 136
  [    3.806387] sec_ts spi0.0: [sec_input] sec_ts_probe: done
  ```
- Device nodes: `sec_touchscreen` active on `/dev/input/event1` (`cap:kt ntouches 10 calib`).

### Boot 2 (Second Consecutive Reboot via `sudo reboot`)
- Execution: Warm reboot issued over SSH (`sudo reboot`). Device rebooted directly into Linux without bootloader stall.
- SSH returned `ONLINE` on first probe (within ~14s).
- Kernel: `Linux mb010 7.3.0-rc6-gs101 #14 SMP PREEMPT Wed Nov 25 14:23:01 CET 2026 aarch64`.
- Hardware register `0x10C40060`: `0x00221222`.
- `dmesg` probe sequence:
  ```
  [    3.848113] sec_ts spi0.0: [sec_input] sec_ts_fw_init: DEVICE ID: 53, 45, 37, 92, 00
  [    3.991622] sec_ts spi0.0: [sec_input] sec_ts_probe: request_irq = 136
  [    3.991973] sec_ts spi0.0: [sec_input] sec_ts_probe: done
  ```
- Input device: `/dev/input/event1` active, `touchmon-events.service` and `touchmon-irq.service` active.
- Phoc, Phosh, and Squeekboard active without lock screen.
- Zero manual module reload required.
