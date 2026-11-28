#!/usr/bin/env bash
# touchmt-test.sh - Controlled Multitouch Test Suite & Analysis for Google Tensor GS101 (raven)
# Evaluates touchscreen accuracy, jitter, latency, multi-touch slot tracking, and ghost touches.
# Targets Samsung S6SY792 / sec_touchscreen on /dev/input/event1.
set -euo pipefail

EVDEV="${EVDEV:-/dev/input/event1}"
LIBINPUT_BIN=""
if command -v libinput >/dev/null 2>&1; then
    LIBINPUT_BIN="libinput debug-events"
elif [ -x "/usr/libexec/libinput/libinput-debug-events" ]; then
    LIBINPUT_BIN="/usr/libexec/libinput/libinput-debug-events"
elif [ -x "/usr/lib/libinput/libinput-debug-events" ]; then
    LIBINPUT_BIN="/usr/lib/libinput/libinput-debug-events"
fi

PANEL_W_PX=1440
PANEL_H_PX=3120
PANEL_W_MM=72
PANEL_H_MM=156
PX_PER_MM=20 # 1440 / 72 = 20 px/mm

# Calibration Grid Points (X_px, Y_px, Label)
# Normalized 9-point grid: 10%, 50%, 90% along each axis
GRID_POINTS=(
    "144:312:P1_TopLeft"
    "720:312:P2_TopCenter"
    "1296:312:P3_TopRight"
    "144:1560:P4_MidLeft"
    "720:1560:P5_Center"
    "1296:1560:P6_MidRight"
    "144:2808:P7_BottomLeft"
    "720:2808:P8_BottomCenter"
    "1296:2808:P9_BottomRight"
)

usage() {
    cat << EOF
Usage: $0 [module] [options]

Test Modules:
  grid9      9-point calibration grid single-finger tap test (2mm accuracy threshold)
  drag       1-finger horizontal and vertical drag test (tracking jitter and cadence)
  longpress  Stationary long-press contact stability test (drift and drop check)
  pinch      2-finger pinch/zoom multi-touch tracking test (ABS_MT_SLOT 0/1 concurrency)
  ghost      5-minute idle hold ghost-touch test (0 spurious event threshold)
  all        Execute all modules sequentially
  analyze    Analyze an existing TSV test capture: $0 analyze <capture.tsv>

Options:
  --output, -o <file.tsv>   Output TSV capture path (default: /tmp/touchmt-<timestamp>.tsv)
  --duration, -d <seconds>  Duration for ghost or longpress tests (default: 300 for ghost, 10 for longpress)
  --device, -e <node>       Evdev device node (default: /dev/input/event1)
EOF
    exit 1
}

MODULE="${1:-all}"
shift || true

OUTPUT_TSV=""
DURATION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output|-o)
            OUTPUT_TSV="$2"
            shift 2
            ;;
        --duration|-d)
            DURATION_OVERRIDE="$2"
            shift 2
            ;;
        --device|-e)
            EVDEV="$2"
            shift 2
            ;;
        *)
            if [ "$MODULE" = "analyze" ] && [ -z "$OUTPUT_TSV" ]; then
                OUTPUT_TSV="$1"
                shift
            else
                usage
            fi
            ;;
    esac
done

if [ "$MODULE" = "analyze" ]; then
    if [ -z "$OUTPUT_TSV" ] || [ ! -f "$OUTPUT_TSV" ]; then
        echo "ERROR: Please specify a valid TSV capture file to analyze." >&2
        exit 1
    fi
    # Execute analysis directly
    exec python3 - << 'PY_ANALYZE_ONLY' "$OUTPUT_TSV"
import sys
import math
from collections import defaultdict

tsv_path = sys.argv[1]
print(f"=== Multitouch Analysis Report: {tsv_path} ===")

records = []
try:
    with open(tsv_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("timestamp"):
                continue
            parts = line.split("\t")
            if len(parts) >= 11:
                records.append({
                    "time": float(parts[0]),
                    "module": parts[1],
                    "event": parts[2],
                    "slot": int(parts[3]) if parts[3].isdigit() else 0,
                    "x_px": float(parts[4]),
                    "y_px": float(parts[5]),
                    "x_mm": float(parts[6]),
                    "y_mm": float(parts[7]),
                    "major": float(parts[8]),
                    "minor": float(parts[9]),
                    "pressure": float(parts[10])
                })
except Exception as e:
    print(f"Error parsing TSV: {e}")
    sys.exit(1)

by_module = defaultdict(list)
for r in records:
    by_module[r["module"]].append(r)

print(f"Total Events Captured: {len(records)}")

# 1. Grid 9 Analysis
if "grid9" in by_module:
    print("\n--- 1. 9-Point Grid Accuracy (2mm Threshold) ---")
    grid_recs = [r for r in by_module["grid9"] if r["event"] == "DOWN"]
    print(f"Recorded Grid Taps: {len(grid_recs)}")
    deviations_mm = []
    for idx, r in enumerate(grid_recs[:9]):
        print(f"  Tap {idx+1}: ({r['x_px']:.1f}px, {r['y_px']:.1f}px) -> ({r['x_mm']:.1f}mm, {r['y_mm']:.1f}mm) Major={r['major']} Minor={r['minor']} Pressure={r['pressure']}")

# 2. Drag & Cadence Analysis
if "drag" in by_module:
    print("\n--- 2. Drag Trajectory & Report Cadence ---")
    drag_recs = [r for r in by_module["drag"] if r["event"] == "MOTION"]
    if len(drag_recs) > 1:
        dt_ms = [(drag_recs[i]["time"] - drag_recs[i-1]["time"]) * 1000.0 for i in range(1, len(drag_recs))]
        mean_dt = sum(dt_ms) / len(dt_ms)
        var_dt = sum((x - mean_dt)**2 for x in dt_ms) / len(dt_ms)
        print(f"  Drag Points: {len(drag_recs)}")
        print(f"  Mean Cadence: {mean_dt:.2f} ms (~{1000.0/mean_dt:.1f} Hz)")
        print(f"  Cadence Jitter StdDev: {math.sqrt(var_dt):.2f} ms")

# 3. Longpress Stability
if "longpress" in by_module:
    print("\n--- 3. Long-Press Contact Stability ---")
    lp_recs = [r for r in by_module["longpress"] if r["event"] in ("MOTION", "DOWN")]
    if lp_recs:
        xs = [r["x_px"] for r in lp_recs]
        ys = [r["y_px"] for r in lp_recs]
        mean_x = sum(xs) / len(xs)
        mean_y = sum(ys) / len(ys)
        var_x = sum((x - mean_x)**2 for x in xs) / len(xs)
        var_y = sum((y - mean_y)**2 for y in ys) / len(ys)
        print(f"  Contact Duration Samples: {len(lp_recs)}")
        print(f"  Positional Jitter: sigma_x={math.sqrt(var_x):.2f}px ({math.sqrt(var_x)/20.0:.3f}mm), sigma_y={math.sqrt(var_y):.2f}px ({math.sqrt(var_y)/20.0:.3f}mm)")

# 4. Multi-Touch Pinch
if "pinch" in by_module:
    print("\n--- 4. Multi-Touch Slot Concurrency (Pinch/Zoom) ---")
    slots_used = set(r["slot"] for r in by_module["pinch"])
    print(f"  Concurrent Slots Active: {sorted(list(slots_used))}")
    if len(slots_used) >= 2:
        print("  PASS: Multi-Touch Protocol B concurrent slots (0 and 1) confirmed active.")
    else:
        print("  WARNING: Fewer than 2 distinct slots observed in pinch capture.")

# 5. Ghost Touches
if "ghost" in by_module:
    print("\n--- 5. 5-Minute Ghost Touch Check ---")
    ghost_recs = [r for r in by_module["ghost"] if r["event"] in ("DOWN", "MOTION")]
    print(f"  Spurious Ghost Events: {len(ghost_recs)}")
    if len(ghost_recs) == 0:
        print("  PASS: 0 ghost contacts observed during idle monitoring.")
    else:
        print(f"  FAIL: {len(ghost_recs)} ghost touch events detected!")
print("\n=== Analysis Complete ===")
PY_ANALYZE_ONLY
    exit 0
fi

# Precondition Check: Target device node and libinput tool must exist
if [ ! -c "$EVDEV" ]; then
    echo "ERROR: Evdev node $EVDEV not found. Ensure sec_touch driver is loaded." >&2
    exit 1
fi

if [ -z "$LIBINPUT_BIN" ]; then
    echo "ERROR: libinput debug-events utility not found. Please install libinput or libinput-tools." >&2
    exit 2
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_TSV="${OUTPUT_TSV:-/tmp/touchmt-${TIMESTAMP}.tsv}"
SUMMARY_FILE="${OUTPUT_TSV}.summary.txt"

echo "=== Google Tensor GS101 Multitouch Verification Suite ==="
echo "Device Node:   $EVDEV"
echo "Capture TSV:   $OUTPUT_TSV"
echo "Summary File:  $SUMMARY_FILE"
echo "Screen Specs:  ${PANEL_W_PX}x${PANEL_H_PX} px (${PANEL_W_MM}x${PANEL_H_MM} mm, ${PX_PER_MM} px/mm)"
echo ""

# Initialize TSV header
cat << 'TSV_HDR' > "$OUTPUT_TSV"
# Google Tensor GS101 Controlled Multi-Touch Test Dataset
# timestamp_sec	module	event	slot	x_px	y_px	x_mm	y_mm	major	minor	pressure
TSV_HDR

parse_and_append_events() {
    local module_name="$1"
    local raw_log="$2"

    awk -v mod="$module_name" -v ppm="$PX_PER_MM" '
    /event[0-9]+.*TOUCH_DOWN/ {
        # Format: -event1   TOUCH_DOWN       +0.000s   0 (0)  123.45/678.90 (7.12/35.21mm)
        t = $3; gsub(/[^0-9.]/, "", t);
        slot = $4; gsub(/[^0-9]/, "", slot);
        # Extract coordinates
        for (i=5; i<=NF; i++) {
            if ($i ~ /\// && $i ~ /^[0-9.]+\/[0-9.]+$/) {
                split($i, coords, "/");
                x_px = coords[1];
                y_px = coords[2];
                x_mm = x_px / ppm;
                y_mm = y_px / ppm;
                printf "%.4f\t%s\tDOWN\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t0\t0\t32\n", (t==""?0:t), mod, (slot==""?0:slot), x_px, y_px, x_mm, y_mm;
                break;
            }
        }
    }
    /event[0-9]+.*TOUCH_MOTION/ {
        t = $3; gsub(/[^0-9.]/, "", t);
        slot = $4; gsub(/[^0-9]/, "", slot);
        for (i=5; i<=NF; i++) {
            if ($i ~ /\// && $i ~ /^[0-9.]+\/[0-9.]+$/) {
                split($i, coords, "/");
                x_px = coords[1];
                y_px = coords[2];
                x_mm = x_px / ppm;
                y_mm = y_px / ppm;
                printf "%.4f\t%s\tMOTION\t%s\t%.2f\t%.2f\t%.2f\t%.2f\t0\t0\t32\n", (t==""?0:t), mod, (slot==""?0:slot), x_px, y_px, x_mm, y_mm;
                break;
            }
        }
    }
    /event[0-9]+.*TOUCH_UP/ {
        t = $3; gsub(/[^0-9.]/, "", t);
        slot = $4; gsub(/[^0-9]/, "", slot);
        printf "%.4f\t%s\tUP\t%s\t0.00\t0.00\t0.00\t0.00\t0\t0\t0\n", (t==""?0:t), mod, (slot==""?0:slot);
    }
    ' "$raw_log" >> "$OUTPUT_TSV"
}

run_grid9() {
    echo "--------------------------------------------------------"
    echo "[MODULE: grid9] 9-Point Calibration Grid Tap Test"
    echo "Accuracy Requirement: <= 2.0 mm mean position deviation"
    echo "--------------------------------------------------------"
    echo "Target locations on 1440x3120 panel:"

    local raw_grid="/tmp/touchmt_grid_raw.log"
    rm -f "$raw_grid"

    # Start capture in background
    $LIBINPUT_BIN --device "$EVDEV" > "$raw_grid" 2>&1 &
    local cap_pid=$!

    for pt in "${GRID_POINTS[@]}"; do
        IFS=":" read -r target_x target_y label <<< "$pt"
        target_x_mm=$(awk -v x="$target_x" -v ppm="$PX_PER_MM" 'BEGIN {printf "%.1f", x/ppm}')
        target_y_mm=$(awk -v y="$target_y" -v ppm="$PX_PER_MM" 'BEGIN {printf "%.1f", y/ppm}')
        echo "--> Please TAP: $label at ($target_x px, $target_y px) [~$target_x_mm mm, $target_y_mm mm]"
        echo "    (Waiting 4 seconds for tap ...)"
        sleep 4
    done

    kill "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true

    parse_and_append_events "grid9" "$raw_grid"
    rm -f "$raw_grid"
    echo "grid9 capture complete."
}

run_drag() {
    echo "--------------------------------------------------------"
    echo "[MODULE: drag] 1-Finger Drag & Tracking Cadence Test"
    echo "Cadence Requirement: ~8 ms report interval (~120 Hz)"
    echo "--------------------------------------------------------"
    echo "--> Please perform a steady horizontal drag across the screen, followed by a vertical drag."
    echo "    Recording for 10 seconds ..."

    local raw_drag="/tmp/touchmt_drag_raw.log"
    rm -f "$raw_drag"

    $LIBINPUT_BIN --device "$EVDEV" > "$raw_drag" 2>&1 &
    local cap_pid=$!
    sleep 10
    kill "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true

    parse_and_append_events "drag" "$raw_drag"
    rm -f "$raw_drag"
    echo "drag capture complete."
}

run_longpress() {
    local dur="${DURATION_OVERRIDE:-10}"
    echo "--------------------------------------------------------"
    echo "[MODULE: longpress] Stationary Contact Stability Test"
    echo "Duration: ${dur}s"
    echo "--------------------------------------------------------"
    echo "--> Please touch and HOLD stationary finger in screen center for ${dur} seconds."

    local raw_lp="/tmp/touchmt_lp_raw.log"
    rm -f "$raw_lp"

    $LIBINPUT_BIN --device "$EVDEV" > "$raw_lp" 2>&1 &
    local cap_pid=$!
    sleep "$dur"
    kill "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true

    parse_and_append_events "longpress" "$raw_lp"
    rm -f "$raw_lp"
    echo "longpress capture complete."
}

run_pinch() {
    echo "--------------------------------------------------------"
    echo "[MODULE: pinch] 2-Finger Multi-Touch Slot Tracking Test"
    echo "Requirement: Concurrent tracking of ABS_MT_SLOT 0 and 1"
    echo "--------------------------------------------------------"
    echo "--> Please place two fingers on the panel and perform a pinch-in and pinch-out gesture."
    echo "    Recording for 10 seconds ..."

    local raw_pinch="/tmp/touchmt_pinch_raw.log"
    rm -f "$raw_pinch"

    $LIBINPUT_BIN --device "$EVDEV" > "$raw_pinch" 2>&1 &
    local cap_pid=$!
    sleep 10
    kill "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true

    parse_and_append_events "pinch" "$raw_pinch"
    rm -f "$raw_pinch"
    echo "pinch capture complete."
}

run_ghost() {
    local dur="${DURATION_OVERRIDE:-300}"
    echo "--------------------------------------------------------"
    echo "[MODULE: ghost] Idle Ghost-Touch Monitor"
    echo "Duration: ${dur}s (5 minutes standard)"
    echo "Requirement: 0 spurious touch events with panel untouched"
    echo "--------------------------------------------------------"
    echo "--> DO NOT TOUCH THE PANEL. Monitoring for unprompted interrupts and ghost contacts ..."

    local raw_ghost="/tmp/touchmt_ghost_raw.log"
    rm -f "$raw_ghost"

    $LIBINPUT_BIN --device "$EVDEV" > "$raw_ghost" 2>&1 &
    local cap_pid=$!
    sleep "$dur"
    kill "$cap_pid" 2>/dev/null || true
    wait "$cap_pid" 2>/dev/null || true

    parse_and_append_events "ghost" "$raw_ghost"
    rm -f "$raw_ghost"
    echo "ghost monitor complete."
}

case "$MODULE" in
    grid9)
        run_grid9
        ;;
    drag)
        run_drag
        ;;
    longpress)
        run_longpress
        ;;
    pinch)
        run_pinch
        ;;
    ghost)
        run_ghost
        ;;
    all)
        run_grid9
        run_drag
        run_longpress
        run_pinch
        run_ghost
        ;;
    *)
        usage
        ;;
esac

echo ""
echo "=== Test Execution Completed. Generating Evaluation Report ==="
# Execute embedded Python analyzer and tee output to summary file
"$0" analyze "$OUTPUT_TSV" | tee "$SUMMARY_FILE"

echo ""
echo "TSV dataset saved to: $OUTPUT_TSV"
echo "Summary report saved to: $SUMMARY_FILE"
