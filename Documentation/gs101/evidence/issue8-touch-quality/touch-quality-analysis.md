# Pixel 6 Pro (raven / GS101) Touch Quality Analysis & Fixes (Issue #8)

## 1. Executive Summary

Following candidate 16 verification, touch was functional but responsiveness was degraded ("works a little, not good"). Analysis of evdev state and libinput logs identified three core defects:
1. **Coordinate Scaling & Resolution Missing**: Evdev reported `resolution = 0` for all axes (`ABS_MT_POSITION_X`, `ABS_MT_POSITION_Y`, `ABS_X`, `ABS_Y`). `libinput` fell back to `1 unit = 1 mm`, treating the 1440x3120 display as 1.44 meters by 3.12 meters (`Size: n/a`). Any tiny finger jitter $>3$ pixels ($0.15\text{ mm}$) exceeded the standard $3\text{ mm}$ tap threshold, causing almost all taps to be interpreted as drags/swipes, while kinetic scroll flings were accelerated by ~20x.
2. **Bottom Edge Swipe Rejection**: An artificial palm rejection hack (`y >= max_y * 95 / 100`) flagged bottom-edge contacts as palms, breaking Phosh's bottom-edge swipe gestures (app drawer / window switcher).
3. **Timestamp Baseline Wrap**: `ts->timestamp` was uninitialized (0) at boot, causing a 32-bit millisecond underflow (`+4294967.293s`) on initial input sync.

Driver fixes were implemented in `drivers/input/touchscreen/sec_ts/sec_ts.c`, packaged into `cand17` (`vendor_boot.img`), and verified live across two consecutive cold reboots. `libinput list-devices` now correctly reports `Size: 72x156mm` and proper millimeter gesture scaling.

---

## 2. Persistent Touch Monitor (`touchmon.service`)

A systemd service was installed on device to record all touch events across reboots with automated log rotation at 5 MB:
- Executable: `/usr/local/bin/touchmon-recorder.py`
- Service: `/etc/systemd/system/touchmon.service`
- Log: `/var/log/touchmon.log` (rotates to `/var/log/touchmon.log.1` at 5 MB)
- Monitored device: `/dev/input/event1` (`sec_touchscreen`) via `libinput-debug-events --show-keycodes`

Service verified active across boots:
```
● touchmon.service - Persistent Touch Event Monitor
     Loaded: loaded (/etc/systemd/system/touchmon.service; enabled; preset: disabled)
     Active: active (running)
     Main PID: 3573 (python3)
        Tasks: 2 (limit: 14358)
        CGroup: /system.slice/touchmon.service
                ├─3573 /usr/bin/python3 /usr/local/bin/touchmon-recorder.py
                └─3605 libinput-debug-events --show-keycodes --device /dev/input/event1
```

---

## 3. Analysis of Recorded Events & Root Cause

### A. Missing Axis Resolution (1.44m x 3.12m Phone)
- **Pixel 6 Pro panel**: $1440 \times 3120$ pixels, physical size $70.1 \times 151.8\text{ mm}$ (~20.55 px/mm).
- In device tree `raven-region.dtb`, `sec,mm2px` was omitted, causing `pdata->mm2px` to default to 1.
- `sec_ts_set_input_prop()` never called `input_abs_set_res()`.
- Evdev `ioctl(EVIOCGABS)` returned `resolution = 0`.
- Libinput fallback behavior:
  ```
  event1   TOUCH_DOWN   +4294967.293s   0 (0) 34.86/84.55 (502.00/2638.00mm)
  ```
  Pixel coordinate (502, 2638) was converted to 502 mm x 2638 mm!
- Consequence:
  - Default tap threshold is 3.0 mm. With 1 px = 1 mm, any touch contact jittering more than 3 pixels became a drag gesture.
  - Kinetic scrolling flung by meters instead of millimeters.

### B. Palm False Positives on Bottom Edge
- Run 7 added:
  ```c
  if (t_id > 0 && ts->plat_data->max_y &&
      ts->coord[t_id].y >= (ts->plat_data->max_y * 95 / 100)) {
      ts->coord[t_id].palm = true;
  }
  ```
- In Phosh, swiping up from $y \ge 95\%$ is the navigation bar gesture to reveal the app launcher. Marking these touches as palm prevented Phosh navigation from recognizing edge swipes.
- Samsung S6SY792 firmware already performs palm and wet detection internally (`Functions: 0x61`).

### C. Report Rate
- Measured inter-frame interval in `/var/log/touchmon.log`: $0.008333\text{ s}$ ($120.0\text{ Hz}$).
- Matches stock S6SY792 hardware sampling rate.

---

## 4. Driver Changes in `drivers/input/touchscreen/sec_ts/sec_ts.c`

1. **Resolution Fallback & Setup**:
   - In `sec_ts_parse_dt`: Default `pdata->mm2px = 20` if DT property is absent or $\le 1$.
   - In `sec_ts_set_input_prop`: Explicitly set resolution using `input_abs_set_res()` for:
     - `ABS_MT_POSITION_X`, `ABS_MT_POSITION_Y` (20 units/mm)
     - `ABS_X`, `ABS_Y` (20 units/mm)
     - `ABS_MT_TOUCH_MAJOR`, `ABS_MT_TOUCH_MINOR` (20 units/mm)
2. **Remove Edge Palm Hack**:
   - Removed artificial $y \ge 95\%$ palm override. Restored symmetric `touch_count` increment/decrement.
3. **Timestamp Initialization**:
   - Initialized `ts->timestamp = ktime_get()` and called `input_set_timestamp(ts->input_dev, ts->timestamp)` before initial `input_sync()` in probe and release handlers.

---

## 5. Verification & Cold Boot Results

### Evdev Properties (`/dev/input/event1`):
```
ABS_MT_POSITION_X   : min=0 max=1439 res=20 (phys=72.0mm)
ABS_MT_POSITION_Y   : min=0 max=3119 res=20 (phys=155.9mm)
ABS_X               : min=0 max=1439 res=20 (phys=72.0mm)
ABS_Y               : min=0 max=3119 res=20 (phys=155.9mm)
ABS_MT_TOUCH_MAJOR  : min=0 max=5100 res=20 (phys=255.0mm)
ABS_MT_TOUCH_MINOR  : min=0 max=5100 res=20 (phys=255.0mm)
```

### Libinput Device Info:
```
Device:                  sec_touchscreen
Kernel:                  /dev/input/event1
Id:                      <unknown>:0000:0000
Group:                   2
Seat:                    seat0, default
Size:                    72x156mm
Capabilities:            keyboard touch
```

### Cold Boot Stability:
- **Cold Boot 1 (Post-flash cand17)**: SSH up in 14s, probe done at 4.16s, IRQ 136 registered to `sec_ts`, `touchmon` running.
- **Cold Boot 2**: SSH up in 18s, probe done at 4.17s, IRQ 136 registered to `sec_ts`, `touchmon` running.
- Zero probe retries, no I/O errors.
