#!/bin/bash
# Shadow_Shield — BLE Link Health Monitor v4
# Uses Bluetooth LINK QUALITY (0-255, higher=better) as the real health signal.
# Honest by design: reports link state; does NOT assert "jamming/attack" from
# a single reading. Only flags "unstable" on genuinely repeated disconnects.
#
# Security model: tracks an allow-list of TRUSTED audio devices. Any connected
# device NOT on that list raises a rogue-device ALERT (security log + desktop
# notification) rather than being silently treated as a healthy link. So an
# unauthorized pairing is detected, not rubber-stamped.
#
# Runs as a systemd --user service (see ble-link-monitor.service). Feeds a genmon
# panel widget via /tmp/ble-monitor-status (see ble-panel.sh).

# --- Trusted devices: MAC (UPPERCASE) -> friendly name ---
# REPLACE these with your own paired devices. List them with:
#     bluetoothctl devices Paired
# Add one line per trusted device. Anything not listed here trips a rogue alert.
declare -A TRUSTED=(
    ["AA:BB:CC:DD:EE:01"]="My Headphones"
    ["AA:BB:CC:DD:EE:02"]="My Earbuds"
)

LOG_DIR="$HOME/.local/share/ble-monitor"
MONITOR_LOG="$LOG_DIR/link-monitor.log"
LQ_LOG="$LOG_DIR/lq-timeline.csv"
SEC_LOG="$LOG_DIR/security-events.log"    # security events (rogue connects)
STATUS_FILE="/tmp/ble-monitor-status"

mkdir -p "$LOG_DIR" 2>/dev/null
[ -f "$LQ_LOG" ] || echo "Timestamp,MAC,LinkQuality,State" > "$LQ_LOG"

# Link-quality thresholds (0-255)
LQ_GOOD=200      # >= this => strong
LQ_WEAK=120      # >= this => fair; below => weak
# Instability detection: many disconnects in a short window
DROP_WINDOW=60   # seconds
DROP_TRIP=4      # this many drops within the window => "unstable"

LAST_LQ=""
LAST_STATE=""
DROP_TIMES=()
declare -A ALERTED=()   # MACs we've already fired a rogue-connect alert for

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$MONITOR_LOG" 2>/dev/null; }
seclog()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$SEC_LOG" 2>/dev/null; }

# Desktop alert for Shadow_Shield security events. Force a display/session bus so
# the popup still fires from the systemd --user service context. -u critical keeps
# it on screen until dismissed. notify: <title> <body>
notify() {
    export DISPLAY="${DISPLAY:-:0}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
    notify-send -u critical -a "Shadow Shield" -i security-high "$1" "$2" 2>/dev/null
}

log "Link monitor started (v4) — allow-list: ${!TRUSTED[*]}"

while true; do
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    # All currently connected BT MACs, normalised to uppercase
    mapfile -t CONNECTED < <(hcitool con 2>/dev/null \
        | grep -oiP '([0-9A-F]{2}:){5}[0-9A-F]{2}' \
        | tr 'a-f' 'A-F' | sort -u)

    # Partition connected devices into trusted (tracked) vs unknown (alert)
    TRACK_MAC=""; TRACK_NAME=""
    UNKNOWN_MACS=()
    for mac in "${CONNECTED[@]}"; do
        if [ -n "${TRUSTED[$mac]+x}" ]; then
            [ -z "$TRACK_MAC" ] && { TRACK_MAC="$mac"; TRACK_NAME="${TRUSTED[$mac]}"; }
        else
            UNKNOWN_MACS+=("$mac")
        fi
    done

    # ---- Rogue-device alerting (security event) ----
    ALERT=0; ALERT_MAC=""
    if [ "${#UNKNOWN_MACS[@]}" -gt 0 ]; then
        ALERT=1; ALERT_MAC="${UNKNOWN_MACS[*]}"
        for umac in "${UNKNOWN_MACS[@]}"; do
            # fire the alert once per connection, not every poll
            if [ -z "${ALERTED[$umac]+x}" ]; then
                ALERTED[$umac]=1
                uname=$(bluetoothctl info "$umac" 2>/dev/null \
                        | grep -oP '^\s*Name:\s*\K.*' | head -1)
                [ -z "$uname" ] && uname="(unknown name)"
                log    "⚠ UNAUTHORIZED BLE device connected: $umac \"$uname\""
                seclog "ALERT unauthorized-connect $umac \"$uname\""
                notify "⚠ Rogue BLE device" "Untrusted device connected:
$uname
$umac"
            fi
        done
    fi
    # Reset alert state for rogue devices that have since disconnected
    for amac in "${!ALERTED[@]}"; do
        still=0
        for mac in "${CONNECTED[@]}"; do [ "$mac" = "$amac" ] && still=1; done
        if [ "$still" -eq 0 ]; then
            unset 'ALERTED[$amac]'
            seclog "cleared unauthorized-connect $amac (disconnected)"
        fi
    done

    # ---- Trusted-device link health ----
    if [ -n "$TRACK_MAC" ]; then
        LQ=$(hcitool lq "$TRACK_MAC" 2>/dev/null | grep -oP 'Link quality: \K[0-9]+')
        if [ -z "$LQ" ]; then LQ="$LAST_LQ"; [ -z "$LQ" ] && LQ=-1; fi

        if [ "$LQ" -lt 0 ] 2>/dev/null; then
            STATE="connected"; HEALTH="unknown"
        elif [ "$LQ" -ge "$LQ_GOOD" ]; then
            STATE="connected"; HEALTH="good"
        elif [ "$LQ" -ge "$LQ_WEAK" ]; then
            STATE="connected"; HEALTH="fair"
            log "Link fair: LQ=$LQ ($TRACK_NAME)"
        else
            STATE="connected"; HEALTH="weak"
            log "Link weak: LQ=$LQ ($TRACK_NAME)"
        fi
        LAST_LQ="$LQ"
    else
        STATE="disconnected"; HEALTH="off"; LQ=0
        now=$(date +%s)
        # Count a drop ONLY on the transition connected -> disconnected.
        # (Polls are not events — being OFF must not read as "unstable".)
        if [ "$LAST_STATE" = "connected" ]; then
            DROP_TIMES+=("$now")
            log "Link dropped (connected -> disconnected)"
        fi
        pruned=()
        for t in "${DROP_TIMES[@]}"; do
            [ $((now - t)) -le "$DROP_WINDOW" ] && pruned+=("$t")
        done
        DROP_TIMES=("${pruned[@]}")
        if [ "${#DROP_TIMES[@]}" -ge "$DROP_TRIP" ]; then
            HEALTH="unstable"
            log "Link UNSTABLE: ${#DROP_TIMES[@]} genuine disconnects within ${DROP_WINDOW}s"
        fi
    fi
    LAST_STATE="$STATE"

    echo "$TS,${TRACK_MAC:-none},$LQ,$STATE/$HEALTH" >> "$LQ_LOG" 2>/dev/null
    # Values are written shell-quoted so the panel can safely `source` this file
    # even when a device name contains an apostrophe (e.g. "Smokin' Buds").
    {
        echo "state=$STATE"
        echo "lq=$LQ"
        echo "health=$HEALTH"
        printf 'device=%q\n'    "${TRACK_NAME:-none}"
        echo "alert=$ALERT"
        printf 'alert_mac=%q\n' "${ALERT_MAC}"
    } > "$STATUS_FILE" 2>/dev/null

    sleep 5
done
