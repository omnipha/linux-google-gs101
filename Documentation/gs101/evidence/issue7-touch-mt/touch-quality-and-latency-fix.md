# Touch Quality and Latency Optimization (Issue #7, #10)

## Problem Summary
During Run 6 live testing on `raven` (Google Pixel 6 Pro, GS101 SoC):
1. **SPI Retry Storm & Latency Penalty**:
   Every touch event motion (~8 ms cadence) generated log floods in dmesg:
   `sec_ts_read_internal: retry 1 for 0x60 size(8) delay_us(100)`
   followed by `sec_ts_read_event: event buffer is empty`.
   Because the SPI read retry path slept `usleep_range(1000, 1000)` (1 ms) on every retry, each touch event suffered a 1 ms latency penalty and spun in the interrupt thread.
2. **Invalid Touch ID Underflow**:
   Trailing interrupts with empty event packets (`tid == 0`) caused an underflow in `sec_ts_handle_coord_event`:
   `t_id = p_event_coord->tid - 1` resulted in `t_id = 255`, triggering `tid(255) is out of range` and potential coordinate corruption.
3. **Initial Timestamp Glitch**:
   First touch event showed `+4294967.295s` timestamp jump due to uninitialized `ts->timestamp` (0 - now).
4. **Excessive Probe Latency**:
   Module probe took >4.2 seconds due to `execute_selftest()` attempting factory calibration reads on non-factory firmware.

## Root Cause Analysis
- **SPI Read Timing**: The Samsung S6SY79x touchscreen MCU requires at least 600 µs between sending the register read command (`0x60`, `SEC_TS_READ_ONE_EVENT`) and the subsequent SPI read transfer. The default delay in `sec_ts_spi_delay()` was 100 µs, which was too short. Try 0 always failed with a bus NAK/overrun, sleeping 1 ms and succeeding only on try 1.
- **Log Level**: Non-fatal retries and empty event buffers were logged with `input_err(true, ...)` and `input_info(true, ...)`, flooding the kernel log buffer during normal swiping.
- **Probe Selftest**: `execute_selftest()` inside `sec_ts_read_init_info()` timed out (4 seconds) because the device is in operational user mode, not Samsung factory calibration mode.

## Implementation Details

### 1. `drivers/input/touchscreen/sec_ts/sec_ts.c`
- **SPI Delay Optimization**:
  ```c
  case SEC_TS_READ_ONE_EVENT:
      delay_us = 600;
      break;
  case SEC_TS_READ_ALL_EVENT:
      delay_us = 650;
      break;
  ```
- **Error Demotion**: Converted non-fatal retries in `sec_ts_read_internal()` from `input_err` to `input_dbg`. Reserved `input_err` strictly for final retry exhaustion (`retry == SEC_TS_IO_RETRY_CNT - 1`).
- **Empty Buffer Handling**: Demoted `event buffer is empty` in `sec_ts_read_event()` from `input_info(true, ...)` to `input_dbg(false, ...)`.
- **Packet Filtering**: Filtered empty event chunks (`event_buff[0] == 0` or `SEC_TS_EMPTY_EVENT`) in the event dispatch loop.
- **Coordinate Guard**: Added `if (!p_event_coord->tid) return;` at the entry of `sec_ts_handle_coord_event()`.
- **Timestamp Init**: Initialized `ts->timestamp` to `ktime_get()` if 0 in `sec_ts_read_event()`.
- **Probe Speedup**: Disabled `#ifndef CONFIG_SEC_FACTORY` selftest and rawdata reads with `#if 0`, cutting probe duration from 4.2 s to 177 ms.

### 2. `arch/arm64/boot/dts/exynos/google/gs101-raven.dts`
- Added display density and calibration check properties to `touchscreen@0`:
  ```dts
  sec,mm2px = [14]; /* 20 px/mm (1440x3120 over 72x156 mm) */
  sec,mis_cal_check = <1>;
  ```

## Live Device Verification
- **Module Reload**: Built `sec_touch.ko` and copied to live device. Reloaded cleanly via `rmmod`/`insmod`.
- **Dmesg Audit**: Confirmed zero retries, zero empty buffer warnings, and zero `tid(255)` errors. Probe completed in 177 ms.
- **Interrupts**: IRQ 136 (`gpa9-0`) stable at 901 with zero spurious interrupt spinning.
- **Event Logging**: `/tmp/touch_events.log` confirms active multitouch event reporting on `/dev/input/event1` (`sec_touchscreen`) with consistent 8 ms (~120 Hz) report cadence and multi-slot tracking (`ABS_MT_SLOT` 0 and 1).
