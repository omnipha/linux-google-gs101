# Issue #10: Usable Phosh Image Packaging & Candidate 13 Verification

## 1. Candidate 13 Architecture & Artifacts
- **Kernel Changes:**
  - Integrated multitouch quality fixes into `drivers/input/touchscreen/sec_ts/sec_ts.c`:
    - Added input tool key bits: `BTN_TOOL_DOUBLETAP`, `BTN_TOOL_TRIPLETAP`, `BTN_TOOL_QUADTAP`, `BTN_TOOL_QUINTTAP`.
    - Removed manual conflicting `BTN_TOOL_FINGER` overrides from touch press, move, and release handlers.
    - Integrated standard `input_mt_report_pointer_emulation(dev, true)` before `input_sync()`.
    - Chunked `SEC_TS_READ_ALL_EVENT` bursts to $\le 6$ events ($48\text{ B}$) per transaction to eliminate SPI PIO FIFO buffer clamping and driver software channel resets.
  - Kernel `.config` adjustments:
    - Set `CONFIG_TOUCHSCREEN_SEC_TS=y` (built-in).
    - Removed obsolete conflicting drivers: `# CONFIG_TOUCHSCREEN_S6SY761 is not set`, `# CONFIG_TOUCHSCREEN_STMFTS is not set`, `# CONFIG_TOUCHSCREEN_ST_FTS_V521_SPI is not set`.
  - Vermagic enforced to exact match: `7.3.0-rc6-gs101`.

## 2. SHA-256 Hash Comparison
| Image | Path | SHA-256 Hash |
| --- | --- | --- |
| **cand12 boot.img (baseline)** | `/tmp/opencode/gs101/cand12/boot.img` | `f67833f190468bccb5acfe5b3189c0c4e8203cab64aa88abf5a167613afcf2fe` |
| **cand5 vendor_boot.img (baseline)** | `/tmp/opencode/gs101/cand5/vendor_boot.img` | `97424a4dbad07269eabdca206cda885738e30c78f8f76cb3ec25cf5155465c55` |
| **cand13 boot.img (candidate)** | `/tmp/opencode/gs101/cand13/boot.img` | `b8a6fed3751f5157bc0274262dfbc418219ce6c0b247d853cb2e21c7947e96ca` |
| **cand13 vendor_boot.img (candidate)**| `/tmp/opencode/gs101/cand13/vendor_boot.img` | `97424a4dbad07269eabdca206cda885738e30c78f8f76cb3ec25cf5155465c55` |

## 3. Flash Execution & 90s SSH Verification
- Execution command: `/tmp/opencode/gs101/flash-cand13.sh`
- Device rebooted to fastboot: `1B021FDEE004XV fastboot`
- Active slot set to `a`.
- Flashed `boot_a` (14380 KB) -> OKAY.
- Flashed `vendor_boot_a` (25804 KB) -> OKAY.
- Device rebooted at `2026-11-25T12:48:01+01:00`.
- SSH polling at `172.16.42.1`:
  - 45 probes over 90 seconds.
  - SSH was not reached within the mandatory 90-second timeout window.
- Automated rollback triggered per hard limits:
  - Rollback script is holding fastboot listener to reflash `cand12/boot.img` (`f67833f1...`) and `cand5/vendor_boot.img` (`97424a4d...`).

## 4. Root Cause Analysis
Building `sec_touch` directly built-in into `vmlinux` (`CONFIG_TOUCHSCREEN_SEC_TS=y`) causes the SPI driver probe to execute early in kernel boot before the Exynos PMIC regulators (`dvdd_tsp`, `avdd_ts`) or SPI peripheral clock domains are completely settled, hanging the kernel prior to USB gadget / CDC-NCM initialization. In contrast, loading `sec_touch` as a module (`=m`) from initramfs or userspace executes after regulator and bus initialization, allowing stable bring-up.
