#!/bin/bash
# Shadow_Shield — BLE Link Health panel widget (XFCE genmon)
# Honest link-quality display; flags rogue (untrusted) connections.
# Reads state written by ble-link-monitor.sh at /tmp/ble-monitor-status.

STATUS_FILE="/tmp/ble-monitor-status"
LOG_DIR="$HOME/.local/share/ble-monitor"
state="unknown"; lq="0"; health="unknown"; device="none"; alert="0"; alert_mac=""
[ -f "$STATUS_FILE" ] && source "$STATUS_FILE"

# A rogue/untrusted device connection takes visual priority — it's a security event.
if [ "${alert:-0}" = "1" ]; then
    echo "<txt><span foreground='red' weight='bold'>⚠ BLE ROGUE</span></txt>"
    echo "<tool>UNAUTHORIZED BLE device connected: ${alert_mac:-unknown}. See security-events.log</tool>"
    echo "<click>xfce4-terminal -e 'tail -f $LOG_DIR/security-events.log'</click>"
    exit 0
fi

case "$health" in
  good)     COLOR="#00ff00"; ICON="🔵"; TXT="BLE";       TIP="$device — link strong (LQ $lq/255)";;
  fair)     COLOR="#ffcc00"; ICON="🔵"; TXT="BLE";       TIP="$device — link fair (LQ $lq/255)";;
  weak)     COLOR="orange";  ICON="📶"; TXT="BLE weak";  TIP="$device — link weak (LQ $lq/255)";;
  unstable) COLOR="red";     ICON="⚠";  TXT="BLE?";      TIP="$device — link unstable: repeated disconnects";;
  off)      COLOR="#888888"; ICON="○";  TXT="BLE off";   TIP="No trusted device connected";;
  *)        COLOR="#888888"; ICON="○";  TXT="BLE";       TIP="$device — status unknown";;
esac

echo "<txt><span foreground='$COLOR' weight='bold'>$ICON $TXT</span></txt>"
echo "<tool>$TIP</tool>"
echo "<click>xfce4-terminal -e 'tail -f $LOG_DIR/link-monitor.log'</click>"
