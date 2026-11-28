# Issue #7 Touchscreen: Owner Physical Test Protocol (Candidate 18 Grip & Swipe Verification)

**Date**: 2026-11-28  
**Target Hardware**: Google Pixel 6 Pro (`raven`, GS101 SoC)  
**Touch Controller**: Samsung S6SY792 (`spi0.0`, driver: `sec_ts` / `sec_touch.ko`)  
**Input Device Node**: `/dev/input/event1` (`sec_touchscreen`)  
**Active Firmware Baseline**: Candidate 18 (`Filters: grip=1, noise=1, deadzone=1, palm=1`)

---

## 1. Overview & Test Objective

In Candidate 18, hardware firmware filters (grip detection, noise filter, edge deadzone, and palm detection) were integrated directly into driver probe (`sec_ts_setup_firmware_filters()`), and edge grip contacts were mapped to `MT_TOOL_PALM` in compliance with Linux Multi-Touch Protocol B. This eliminated 100% of idle ghost touches (down from 92.0% in uncalibrated baselines).

**Objective**: Verify that when the owner holds the phone naturally by its curved edges, the grip filter correctly suppresses accidental edge contacts while cleanly recognizing an intentional **bottom-edge swipe** (the fundamental Phosh navigation gesture to unlock the screen or access the application drawer).

---

## 2. Touch Coordinate Geometry & Phosh Gesture Mapping

- **X Axis Range**: `0` (Left) to `1439` (Right)
- **Y Axis Range**: `0` (Top) to `3119` (Bottom)
- **Bottom Navigation Bar**: $Y \ge 2900$
- **Curved Edge Grip Zones**: $X \le 50$ (Left Edge) and $X \ge 1389$ (Right Edge)
- **Bottom-Edge Swipe Gesture**:
  - Touch-Down: Start at the bottom border ($Y \in [2900, 3119]$, $X \approx 720$).
  - Continuous Drag: Move smoothly upwards to the center ($Y \le 1800$).
  - Touch-Up: Release finger.

---

## 3. Physical Test Execution Steps (For Device Owner)

Follow these 3 simple physical steps while holding the phone:

### Step 1: Natural Grip Hold (Resting Palms/Fingers on Bezel)
- Pick up the phone with one or two hands as you would normally hold it.
- Allow the flesh of your palm and fingers to rest against the left and right curved glass edges.
- **Do not swipe yet** for 5 seconds.
- *Expected result*: The screen does not jitter, no random buttons or UI elements are pressed, and no ghost touches occur.

### Step 2: Intentional Bottom-Edge Swipe
- While maintaining your natural grip on the sides, use your right or left thumb to touch the bottom edge of the glass (below the Phosh navigation bar).
- Swipe steadily upward toward the middle of the display in a single fluid motion.
- Lift your thumb.
- *Expected result*: The lock screen slides upward or the Phosh app drawer/overview opens smoothly without stutter or dropouts.

### Step 3: Multi-Touch (Two-Finger Drag)
- Place two fingers simultaneously near the center of the display and drag them apart or together (pinch/spread).
- *Expected result*: Both touch points are tracked independently without interference.

---

## 4. Exact On-Device Monitoring Commands (Copy-Paste)

Execute these commands from your host workstation via SSH to monitor and record the touch events in real time:

### Command 4.1: Pre-Test Driver & Filter Status Check
Confirm that all 4 hardware filters are armed:
```bash
ssh user@172.16.42.1 'cat /sys/class/sec/tsp/status'
```
*Expected Output*:
```text
Boot status: 0x20
Filters: grip=1, noise=1, deadzone=1, palm=1
Report rate: 120
```

---

### Command 4.2: Live Evtest Event Stream Capture
Run an automated 10-second capture while performing the bottom swipe:
```bash
ssh user@172.16.42.1 << 'EOF'
sudo evtest /dev/input/event1 | tee /tmp/touch_test_raw.log
EOF
```
*Key Events to Observe in Output*:
1. **Touch-Down**:
   ```text
   Event: code 47 (ABS_MT_SLOT), value 0
   Event: code 57 (ABS_MT_TRACKING_ID), value <unique_id>
   Event: code 53 (ABS_MT_POSITION_X), value ~720
   Event: code 54 (ABS_MT_POSITION_Y), value ~3000
   Event: code 330 (BTN_TOUCH), value 1
   Event: code 325 (BTN_TOOL_FINGER), value 1
   Event: code 0 (SYN_REPORT), value 0
   ```
2. **Upward Motion**:
   ```text
   Event: code 54 (ABS_MT_POSITION_Y), value 2800 -> 2400 -> 1900 -> 1500
   Event: code 0 (SYN_REPORT), value 0
   ```
3. **Touch-Up (Lift)**:
   ```text
   Event: code 57 (ABS_MT_TRACKING_ID), value -1
   Event: code 330 (BTN_TOUCH), value 0
   Event: code 325 (BTN_TOOL_FINGER), value 0
   Event: code 0 (SYN_REPORT), value 0
   ```

---

### Command 4.3: Libinput Gesture & Protocol Validation
Verify how libinput and the Phoc compositor process the touch:
```bash
ssh user@172.16.42.1 'sudo libinput debug-events --show-keycodes'
```
*Expected Output*:
```text
event1   TOUCH_DOWN       +0.000s   0 (0) 50.00/96.20 (720.00/3000.00mm)
event1   TOUCH_MOTION     +0.016s   0 (0) 50.00/80.00 (720.00/2500.00mm)
event1   TOUCH_MOTION     +0.032s   0 (0) 50.00/50.00 (720.00/1500.00mm)
event1   TOUCH_FRAME      +0.032s
event1   TOUCH_UP         +0.048s   0 (0)
event1   TOUCH_FRAME      +0.048s
```

---

### Command 4.4: Visual Screenshot Verification
Capture a screenshot to prove that the Phosh lock screen unlocked or the app drawer opened:
```bash
# Capture screenshot on device
ssh user@172.16.42.1 'grim /tmp/phosh_touch_result.png'

# Download screenshot to host for review
scp user@172.16.42.1:/tmp/phosh_touch_result.png Documentation/gs101/evidence/issue7-touch-mt/
```

---

## 5. Success / Failure Evaluation Criteria

| Evaluation Check | Success Criteria (PASS) | Failure Indicator (FAIL) |
| :--- | :--- | :--- |
| **Grip Filter Suppression** | Curved-edge contacts from resting palms are dropped or tagged as `MT_TOOL_PALM`. Zero accidental clicks. | Edge grip triggers spurious button presses or locks out the active swipe. |
| **Ghost Contact Rate** | `ghost=0`. No coordinate packets emitted when no fingers touch the glass. | Phantom touches appearing at corners ($99.9\% / 99.8\%$). |
| **Slot Allocation** | Active finger assigned cleanly to `ABS_MT_SLOT 0`; unique tracking ID allocated and retired cleanly (`-1`). | Slot ID flapping, missing `SYN_REPORT`, or tracking ID leaks. |
| **Motion Tracking** | Smooth monotonic decrease in `ABS_MT_POSITION_Y` ($3000 \to 1500$) without sudden jumps. | Touch coordinates erratic or jumping randomly between slots. |
| **Compositor Reaction** | Phosh shell immediately executes unlock or overview animation. | Compositor ignores gesture due to contradictory tool state. |
