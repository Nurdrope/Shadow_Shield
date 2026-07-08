#!/bin/bash
# Shadow_Shield — BLE allow-list provisioner
# Trust-on-first-use: reads the devices you have ALREADY paired (BlueZ bonded
# devices — things you personally authorized) and writes them into the monitor's
# allow-list. Run this once at install, or any time you want to re-baseline.
#
# It NEVER enables enforcement on its own. After reviewing the generated list you
# opt into deny-by-default by setting AUTO_KICK=1 in ble-link-monitor.sh.

CONF_DIR="$HOME/.config/ble-monitor"
CONF="$CONF_DIR/trusted.conf"
mkdir -p "$CONF_DIR"

mapfile -t PAIRED < <(bluetoothctl devices Paired 2>/dev/null)
if [ "${#PAIRED[@]}" -eq 0 ]; then
    echo "No paired devices found. Pair your gear first (bluetoothctl), then re-run."
    exit 1
fi

[ -f "$CONF" ] && cp "$CONF" "$CONF.bak.$(date +%s)" && echo "Backed up existing allow-list."

{
    echo "# Shadow_Shield BLE allow-list — generated $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# by ble-provision.sh from currently-paired (authorized) devices."
    echo "# Edit freely: add/remove lines, then restart ble-link-monitor.service."
    echo "declare -A TRUSTED=("
} > "$CONF"

echo "Seeding allow-list from ${#PAIRED[@]} paired device(s):"
for line in "${PAIRED[@]}"; do
    # line: "Device AA:BB:CC:DD:EE:FF Friendly Name"
    mac=$(awk '{print $2}' <<<"$line")
    name=$(cut -d' ' -f3- <<<"$line")
    icon=$(bluetoothctl info "$mac" 2>/dev/null | grep -oP '^\s*Icon:\s*\K.*' | head -1)
    printf '    ["%s"]=%q  # %s\n' "$mac" "$name" "${icon:-unknown}" >> "$CONF"
    echo "  + $mac  $name  [${icon:-unknown}]"
done
echo ")" >> "$CONF"

echo
echo "Wrote $CONF"
echo "Review it, then (optionally) enable enforcement: set AUTO_KICK=1 in ble-link-monitor.sh"
echo "Restart to apply: systemctl --user restart ble-link-monitor.service"
