#!/bin/sh
# touchmon.sh - log real touch events from /dev/input/event1 (sec_touchscreen)
# and sample the IRQ97 counter from /proc/interrupts.
#
# The monitors run as transient systemd units (systemd-run), so they are
# independent of the SSH session and survive an SSH disconnect.
#
# Logs:
#   /tmp/touch_events.log - timestamped libinput debug-events lines
#   /tmp/irq97.log         - timestamped IRQ97 counter samples (every 5 s)
#
# Usage (on device):  sudo /tmp/touchmon.sh start|stop|status

EVDEV=/dev/input/event1
DEBUG_EVENTS=/usr/libexec/libinput/libinput-debug-events
EVENTS_LOG=/tmp/touch_events.log
IRQ_LOG=/tmp/irq97.log
EVENTS_UNIT=touchmon-events.service
IRQ_UNIT=touchmon-irq.service

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

start_monitor() {
    systemctl is-active --quiet "$EVENTS_UNIT" && {
        echo "$EVENTS_UNIT already active"; return 0; }

    # --- touch event log: only real event lines, timestamped --------------
    systemd-run --unit="$EVENTS_UNIT" \
        --description="touch event monitor /dev/input/event1 (issue 6)" \
        /bin/sh -c "
            $DEBUG_EVENTS --device $EVDEV 2>&1 | while IFS= read -r line; do
                printf '%s %s\n' \"\$(date '+%Y-%m-%d %H:%M:%S')\" \"\$line\"
            done >> $EVENTS_LOG
        "

    # --- IRQ97 sampler: every 5 s append the current counter --------------
    systemd-run --unit="$IRQ_UNIT" \
        --description="IRQ97 sampler /proc/interrupts (issue 6)" \
        /bin/sh -c "
            while true; do
                line=\$(grep -E 'sec_ts' /proc/interrupts | head -1)
                printf '%s %s\n' \"\$(date '+%Y-%m-%d %H:%M:%S')\" \"\$line\" >> $IRQ_LOG
                sleep 5
            done
        "

    sleep 2
    log "started: $EVENTS_UNIT=$(systemctl is-active $EVENTS_UNIT 2>/dev/null), $IRQ_UNIT=$(systemctl is-active $IRQ_UNIT 2>/dev/null)"
}

stop_monitor() {
    systemctl stop "$EVENTS_UNIT" "$IRQ_UNIT" 2>/dev/null
    systemctl reset-failed "$EVENTS_UNIT" "$IRQ_UNIT" 2>/dev/null
    echo "stopped"
}

status_monitor() {
    echo "events unit: $(systemctl is-active $EVENTS_UNIT 2>/dev/null)  (pid $(systemctl show -p MainPID --value $EVENTS_UNIT 2>/dev/null))"
    echo "irq unit:    $(systemctl is-active $IRQ_UNIT 2>/dev/null)  (pid $(systemctl show -p MainPID --value $IRQ_UNIT 2>/dev/null))"
    echo "events log:  $(wc -l < $EVENTS_LOG 2>/dev/null || echo 0) lines"
    echo "irq log:     $(wc -l < $IRQ_LOG 2>/dev/null || echo 0) lines"
    tail -3 "$EVENTS_LOG" 2>/dev/null
    tail -2 "$IRQ_LOG" 2>/dev/null
}

case "$1" in
    start)  start_monitor ;;
    stop)   stop_monitor ;;
    status) status_monitor ;;
    *)      echo "usage: $0 start|stop|status"; exit 1 ;;
esac
