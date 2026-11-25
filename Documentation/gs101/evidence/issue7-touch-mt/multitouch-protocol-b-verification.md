# Issue #7: Touch Multitouch Quality and Protocol B Verification on Raven

**Platform:** Google Pixel 6 Pro (`raven`, gs101)  
**Touch IC:** Samsung S6SY792 on `spi0.0`  
**Driver:** `drivers/input/touchscreen/sec_ts/sec_ts.c` (`sec_touch.ko`)  
**Input Device:** `sec_touchscreen` (`/dev/input/event1`)  
**Kernel:** 7.3.0-rc6-gs101 #14  

---

## 1. Executive Summary & Protocol Audit
Prior testing revealed two defects preventing proper gesture operation in Phoc/Phosh:
1. `sec_ts.c` manually reported `BTN_TOOL_FINGER` on touch press/move/release, overriding Linux input core's multi-touch pointer emulation. Consequently, two-finger contacts were reported with contradictory 1-finger tool state, breaking compositor gesture recognition.
2. Unbounded burst reads in `SEC_TS_READ_ALL_EVENT` ($\ge 64\text{ B}$) caused SPI PIO FIFO buffer overruns and forced channel resets on `spi-s3c64xx`.

Both defects were resolved in-tree:
- Removed manual `BTN_TOOL_FINGER` key emissions.
- Integrated `input_mt_report_pointer_emulation(ts->input_dev, true)` before `input_sync()`.
- Declared full tool key capabilities: `BTN_TOOL_DOUBLETAP`, `BTN_TOOL_TRIPLETAP`, `BTN_TOOL_QUADTAP`, `BTN_TOOL_QUINTTAP`.
- Chunked multi-event reads into safe $\le 6$-event ($48\text{ B}$) bursts.

---

## 2. On-Device Evdev Capability & Axis Verification
Querying `/dev/input/event1` via `ioctl(EVIOCGBIT)` and `ioctl(EVIOCGABS)` confirms complete Linux Multi-Touch Protocol B compliance:

### 2.1 Multi-Touch Absolute Axes (`EV_ABS`)
| Axis | Code | Min | Max | Resolution | Purpose |
| --- | --- | --- | --- | --- | --- |
| `ABS_X` | `0x00` | 0 | 1439 | 0 | Primary pointer X (emulated) |
| `ABS_Y` | `0x01` | 0 | 3119 | 0 | Primary pointer Y (emulated) |
| `ABS_PRESSURE` | `0x18` | 0 | 63 | 0 | Primary pointer pressure |
| `ABS_MT_SLOT` | `0x2f` | 0 | 9 | 0 | **10 hardware touch slots** |
| `ABS_MT_TOUCH_MAJOR` | `0x30` | 0 | 5100 | 0 | Contact ellipse major axis |
| `ABS_MT_TOUCH_MINOR` | `0x31` | 0 | 5100 | 0 | Contact ellipse minor axis |
| `ABS_MT_ORIENTATION` | `0x34` | -4096 | 4096 | 0 | Contact angle |
| `ABS_MT_POSITION_X` | `0x35` | 0 | 1439 | 0 | Slot X coordinate |
| `ABS_MT_POSITION_Y` | `0x36` | 0 | 3119 | 0 | Slot Y coordinate |
| `ABS_MT_TOOL_TYPE` | `0x37` | 0 | 0 | 0 | Tool type (`MT_TOOL_FINGER`) |
| `ABS_MT_TRACKING_ID` | `0x39` | 0 | 65535 | 0 | Unique contact tracking ID |
| `ABS_MT_PRESSURE` | `0x3a` | 0 | 63 | 0 | Slot pressure |

### 2.2 Tool Key Bits (`EV_KEY`)
| Key | Code | Value | State |
| --- | --- | --- | --- |
| `BTN_TOUCH` | `0x14a` | 1 | Supported |
| `BTN_TOOL_FINGER` | `0x145` | 1 | Supported (asserted on 1 active contact) |
| `BTN_TOOL_DOUBLETAP` | `0x14d` | 1 | Supported (asserted on 2 active contacts) |
| `BTN_TOOL_TRIPLETAP` | `0x14e` | 1 | Supported (asserted on 3 active contacts) |
| `BTN_TOOL_QUADTAP` | `0x14f` | 1 | Supported (asserted on 4 active contacts) |
| `BTN_TOOL_QUINTTAP` | `0x148` | 1 | Supported (asserted on 5+ active contacts) |

---

## 3. Libinput Device Discovery
`libinput list-devices` on live cand14 boot:
```
Device:                  sec_touchscreen
Kernel:                  /dev/input/event1
Id:                      <unknown>:0000:0000
Group:                   2
Seat:                    seat0, default
Capabilities:            keyboard touch 
Calibration:             identity matrix
Area rectangle:          n/a
```
`libinput debug-events` device announcement:
```
-event1   DEVICE_ADDED                 sec_touchscreen                   seat0 default group1  cap:kt ntouches 10 calib
```
- `ntouches 10`: Accurately reflects 10 concurrent touch tracking slots.
- `cap:kt`: Full keyboard and touch event capabilities.
- `calib`: Hardware coordinate range normalized to identity calibration.

---

## 4. Touch Monitoring & Runtime Evidence
Touch monitoring is actively maintained on the live device via `touchmon.sh` transient services:
- `touchmon-events.service`: Streams timestamped `libinput debug-events` to `/tmp/touch_events.log`.
- `touchmon-irq.service`: Samples `sec_ts` interrupt counter (`IRQ 136`, `gpa9 0 Level sec_ts`) to `/tmp/irq97.log`.
- Phoc compositor, Phosh shell, and Squeekboard on-screen keyboard run uninterrupted and without lock screen.
