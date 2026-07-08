#!/bin/bash
# Shadow_Shield — BLE Link Health Monitor v5
# Uses Bluetooth LINK QUALITY (0-255, higher=better) as the real health signal.
# Honest by design: reports link state; does NOT assert "jamming/attack" from
# a single reading. Only flags "unstable" on genuinely repeated disconnects.
#
# Security model — deny-by-default:
#   * Allow-list of TRUSTED devices (seed it from your ALREADY-paired devices
#     with ble-provision.sh — trust-on-first-use).
#   * Any connected device NOT on the list is a rogue: alerted, and (if AUTO_KICK)
#     disconnected + blocked so BlueZ refuses it thereafter.
#   * Anti-lockout: a rogue keyboard/mouse (HID) is only auto-blocked when a
#     non-Bluetooth input fallback exists (built-in/USB keyboard). Otherwise it is
#     held + alerted, so you can't block your only way to type.
#
# Runs as a systemd --user service (see ble-link-monitor.service). Feeds a genmon
# panel widget via /tmp/ble-monitor-status (see ble-panel.sh).

# --- Trusted devices: MAC (UPPERCASE) -> friendly name ---
# Inline defaults are placeholders. The REAL list should be generated from your
# already-paired devices:  ble-provision.sh   ->  ~/.config/ble-monitor/trusted.conf
declare -A TRUSTED=(
    ["AA:BB:CC:DD:EE:01"]="My Headphones"
    ["AA:BB:CC:DD:EE:02"]="My Earbuds"
)
TRUST_CONF="$HOME/.config/ble-monitor/trusted.conf"
[ -f "$TRUST_CONF" ] && source "$TRUST_CONF"

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

# Enforcement: deny-by-default. 1 = disconnect + block untrusted devices on sight.
# Ships as 0 (alert-only) so a fresh install can't kick your own gear before you
# have provisioned the allow-list. Turn on AFTER running ble-provision.sh.
# Re-admit a device later with: bluetoothctl unblock <MAC>
AUTO_KICK=0

# Anti-lockout: is there a non-Bluetooth keyboard (built-in/USB) to fall back on?
# If yes, blocking a rogue BT keyboard can't lock you out, so we enforce uniformly.
HAS_INPUT_FALLBACK=0
if grep -qiE 'Name=.*(AT Translated|USB.*Keyboard|PS/2.*Keyboard)' /proc/bus/input/devices 2>/dev/null; then
    HAS_INPUT_FALLBACK=1
fi

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

log "Link monitor started (v5) — allow-list: ${!TRUSTED[*]} | AUTO_KICK=$AUTO_KICK | input_fallback=$HAS_INPUT_FALLBACK"

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
                uinfo=$(bluetoothctl info "$umac" 2>/dev/null)
                uname=$(grep -oP '^\s*Name:\s*\K.*' <<<"$uinfo" | head -1)
                uicon=$(grep -oP '^\s*Icon:\s*\K.*' <<<"$uinfo" | head -1)
                [ -z "$uname" ] && uname="(unknown name)"
                log    "⚠ UNAUTHORIZED BLE device connected: $umac \"$uname\" [${uicon:-unknown}]"
                seclog "ALERT unauthorized-connect $umac \"$uname\" [${uicon:-unknown}]"

                if [ "$AUTO_KICK" != "1" ]; then
                    notify "⚠ Rogue BLE device" "Untrusted device connected:
$uname
$umac"
                    continue
                fi

                # Enforcement on. Decide whether it's safe to block an input device.
                is_hid=0
                case "$uicon" in input-*|*keyboard*|*mouse*) is_hid=1 ;; esac

                if [ "$is_hid" -eq 1 ] && [ "$HAS_INPUT_FALLBACK" -ne 1 ]; then
                    # Anti-lockout: no non-BT keyboard to fall back on — do NOT block
                    # the only input path. Disconnect to stop injection, then alert.
                    bluetoothctl disconnect "$umac" >/dev/null 2>&1
                    log    "→ HELD (input device, no fallback): disconnected but NOT blocked $umac"
                    seclog "HOLD input-device $umac (no input fallback; manual review)"
                    notify "⚠ Rogue INPUT device!" "Untrusted keyboard/mouse — disconnected, NOT blocked (no fallback keyboard). Review manually:
$uname
$umac"
                else
                    # Uniform deny-by-default: drop the link and block reconnects.
                    bluetoothctl disconnect "$umac" >/dev/null 2>&1
                    bluetoothctl block      "$umac" >/dev/null 2>&1
                    log    "→ ENFORCE: disconnected + blocked $umac"
                    seclog "ENFORCE disconnect+block $umac"
                    notify "⛔ Rogue BLE device DENIED" "Untrusted device kicked & blocked:
$uname
$umac"
                fi
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
