#!/bin/bash
# Shadow_Shield — set the Bluetooth adapter NON-pairable (and non-discoverable)
# at session start. Preventive hardening: no NEW device can bond unless you
# deliberately re-enable pairing to add gear:
#     bluetoothctl pairable on   # ...pair + provision..., then:
#     bluetoothctl pairable off
# Runs as a user oneshot — no root needed (the session owns the adapter).

LOG="$HOME/.local/share/ble-monitor/security-events.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

# Wait (up to ~20s) for a powered controller — Bluetooth may still be coming up.
for _ in $(seq 1 20); do
    state=$(timeout 5 bluetoothctl show 2>/dev/null)
    if grep -q 'Controller' <<<"$state" && grep -q 'Powered: yes' <<<"$state"; then
        break
    fi
    sleep 1
done

timeout 5 bluetoothctl pairable off      >/dev/null 2>&1
timeout 5 bluetoothctl discoverable off  >/dev/null 2>&1

# Record the resulting state for provenance.
show=$(timeout 5 bluetoothctl show 2>/dev/null)
pair=$(grep -oP 'Pairable:\s*\K\w+'     <<<"$show")
disc=$(grep -oP 'Discoverable:\s*\K\w+' <<<"$show")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] HARDEN pairable=${pair:-?} discoverable=${disc:-?}" >> "$LOG"
