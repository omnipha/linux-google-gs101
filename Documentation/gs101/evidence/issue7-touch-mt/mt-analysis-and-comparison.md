# Multitouch Quality, Event Parser Analysis, and Comparison with LineageOS

**Issue:** #7  
**Platform:** Google Pixel 6 Pro (`raven`, gs101)  
**Touch Hardware:** Samsung S6SY792 / S6SY79x on `spi0.0`  
**Input Device:** `sec_touchscreen` (`/dev/input/event1`)  

---

## 1. Executive Summary

While single-touch input (tap, drag, unlock swipe) is confirmed functional on `raven` (verified on-device 2026-11-25 11:44 CET), multi-finger gestures (pinch-to-zoom, 2-finger scroll) are degraded or unreliable.

Analysis of the `sec_ts` driver implementation, Linux input subsystem MT Protocol B conventions, and comparison against LineageOS / Google stock kernel sources reveals two distinct root causes:
1. **Broken Multi-Touch Pointer Emulation in Driver**:
   `sec_ts.c` hardcodes `input_report_key(ts->input_dev, BTN_TOOL_FINGER, 1)` across all active touch slots, rather than delegating pointer emulation to `input_mt_report_pointer_emulation(dev, true)`. Consequently, when 2 fingers touch the panel, `libinput` receives contradictory input: multi-touch slots report 2 contacts, but the legacy key report states `BTN_TOOL_FINGER` (1 finger) instead of `BTN_TOOL_DOUBLETAP`. This corrupts `libinput` gesture state machines.
2. **SPI PIO Buffer Clamping & Software Reset Bug on Multi-Event Reads**:
   In `sec_ts_read_event()`, when multiple fingers move simultaneously, the hardware event FIFO accumulates multiple coordinate packets ($> 6$ events). The driver attempts a burst read via `SEC_TS_READ_ALL_EVENT` ($N \times 8$ bytes). Transfers $\ge 64$ bytes in `drivers/spi/spi-s3c64xx.c` trigger `s3c64xx_flush_fifo()` and software channel reset `S3C64XX_SPI_CH_SW_RST` mid-burst (due to missing SPI DMA in mainline gs101 DT), dropping multi-finger packets with `-EIO` and `TX overrun`.

---

## 2. Event Parser & Kernel MT Protocol B Audit

### 2.1 Coordinate Event Parser (`sec_ts_handle_coord_event`)
The hardware coordinate packet structure is 8 bytes (`struct sec_ts_event_coordinate`):
```c
struct sec_ts_event_coordinate {
    u8 eid:2;          /* Event ID: 0 = status, 1 = coordinate, 2 = gesture */
    u8 tid:4;          /* Touch ID: 1..10 (1-based from hardware) */
    u8 tchsta:2;       /* Touch State: 0 = release, 1 = press, 2 = move */
    u8 x_11_4;         /* X coordinate upper 8 bits */
    u8 y_11_4;         /* Y coordinate upper 8 bits */
    u8 y_3_0:4;        /* Y coordinate lower 4 bits */
    u8 x_3_0:4;        /* X coordinate lower 4 bits */
    u8 major;          /* Touch major axis length */
    u8 minor;          /* Touch minor axis length */
    u8 z:6;            /* Touch pressure / Z */
    u8 ttype_3_2:2;    /* Touch type upper 2 bits */
    u8 left_event:6;   /* Remaining events in FIFO */
    u8 ttype_1_0:2;    /* Touch type lower 2 bits */
} __packed;
```

Slot mapping:
- `t_id = (p_event_coord->tid - 1);` correctly maps 1-based hardware touch IDs to 0-based Linux MT slots ($0 \dots 9$).
- `input_mt_slot(ts->input_dev, t_id);` selects the target slot.
- `input_mt_report_slot_state(ts->input_dev, MT_TOOL_FINGER, active);` assigns or invalidates `ABS_MT_TRACKING_ID`.
- Coordinate scaling:
  - `ABS_MT_POSITION_X`: `(x_11_4 << 4) | x_3_0` (range $0 \dots 1440$)
  - `ABS_MT_POSITION_Y`: `(y_11_4 << 4) | y_3_0` (range $0 \dots 3120$)
  - `ABS_MT_PRESSURE`: `z & 0x3F`
  - `ABS_MT_TOUCH_MAJOR`: `major * mm2px`
  - `ABS_MT_TOUCH_MINOR`: `minor * mm2px`

### 2.2 Defects Identified in `sec_ts.c`

1. **Incorrect Tool Key Reporting (`BTN_TOOL_FINGER`)**:
   In `sec_ts.c:2161` and `2248`:
   ```c
   input_report_key(ts->input_dev, BTN_TOUCH, 1);
   input_report_key(ts->input_dev, BTN_TOOL_FINGER, 1);
   ```
   Under Linux MT Protocol B, `BTN_TOOL_FINGER` must only be asserted when exactly one finger is touching. When two fingers are down, `BTN_TOOL_DOUBLETAP` must be asserted instead. Manually hardcoding `BTN_TOOL_FINGER` violates protocol specifications and prevents user-space compositors (Phoc/Phosh) from activating two-finger pinch and scroll handlers.
   **Fix**: Call `input_mt_report_pointer_emulation(ts->input_dev, true)` before `input_sync(ts->input_dev)` in `sec_ts_read_event()`, and remove the manual `BTN_TOOL_FINGER` assignments.

2. **Burst Read Overflow in `SEC_TS_READ_ALL_EVENT`**:
   In `sec_ts_read_event()` lines 3161–3166:
   When `left_event_count >= 7`, total transfer length exceeds 63 bytes. Under PIO mode without DMA, `spi-s3c64xx` issues `S3C64XX_SPI_CH_SW_RST` mid-burst.
   **Fix**: Clamp `sec_ts_read` transfers to at most 6 events ($48\text{ B} + 8\text{ B} = 56\text{ B} < 64\text{ B}$), or iterate single-event reads (`SEC_TS_READ_ONE_EVENT`).

---

## 3. Comparison with LineageOS / Stock Pixel Kernel

| Feature | Current Mainline Driver (`sec_ts.c`) | LineageOS / Google Stock (`lineage-20` / AOSP) | Analysis / Impact |
| --- | --- | --- | --- |
| **Compatible** | `sec,sec_ts` | `sec,sec_ts` | Exact match with Raven panel hardware. |
| **MT Protocol** | Type B (`input_mt_init_slots`, direct) | Type B (`input_mt_init_slots`, direct) | Architecture is compatible. |
| **Max Contacts** | 10 (`MAX_SUPPORT_TOUCH_COUNT`) | 10 | Identical slot count. |
| **Pointer Emulation** | Manual `BTN_TOOL_FINGER` (defective) | Handled via core or `touch_offload` | Mainline driver lacks multi-finger tool transitions. |
| **Offload Engine** | Disabled (`CONFIG_TOUCHSCREEN_OFFLOAD` unset) | Enabled (`touch_offload.ko`, AOC IPC) | Mainline runs purely on AP; offload not needed for direct input. |
| **Bus Arbitration** | Static GPIO hog (`ts-spi-sel` low) | Dynamic TBN (`touch_bus_negotiator`) | Static AP ownership works reliably without AOC complexity. |
| **SPI Transport** | PIO mode (`spi-s3c64xx`, FIFO depth 64) | DMA mode (`pdma1` rx/tx channels) | PIO requires transfer sizing $< 64$ B to prevent software reset aborts. |
| **Panel Map / Bridge** | Bypassed fallback on simpledrm | Bound to Exynos DECON connector DRM bridge | Mainline simpledrm operates cleanly without DRM bridge dependency. |

---

## 4. Conclusion & Action Plan for Issue #10

1. **Protocol Compliance**:
   Refactor `sec_ts.c` to use `input_mt_report_pointer_emulation(ts->input_dev, true)` and remove conflicting manual `BTN_TOOL_FINGER` key events.
2. **SPI Transfer Safety**:
   Cap multi-event reads in `sec_ts_read_event()` to $\le 6$ events per transaction to avoid the 64-byte PIO reset bug.
3. **Packaging**:
   Include these driver enhancements in the consolidated candidate image build for Issue #10.
