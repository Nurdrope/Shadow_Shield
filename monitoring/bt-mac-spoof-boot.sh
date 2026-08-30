#!/bin/bash
# Shadow_Shield — randomize the Bluetooth adapter's public address at BOOT.
#
# Generates a fresh locally-administered MAC (bit pattern xx:xx:xx & 0x02, so
# it can never collide with a real vendor OUI) on every boot and writes it to
# the controller via btmgmt. Rotating by design — mirrors the WiFi
# scan-rand-mac-address behavior in privacy/00-privacy.conf. This WILL break
# any existing Bluetooth pairings on every reboot, since the adapter's
# address changes out from under them; re-pair after each boot if needed.
#
# Not all chipsets honor a public-addr override — some silently ignore it or
# revert on adapter reset. Verified working on Intel AX211 (2026-08).
#
# Install to /usr/local/bin; pair with bt-mac-spoof-boot.service.
# Logs to journald (stdout) + syslog (tag: shadow-shield). Does NOT use $HOME.

IFACE="${1:-hci0}"

# Wait (up to ~30s) for a powered controller — the adapter may still be
# coming up when this runs.
for _ in $(seq 1 30); do
    if hciconfig "$IFACE" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! hciconfig "$IFACE" >/dev/null 2>&1; then
    echo "HARDEN(boot) bt-mac-spoof FAILED adapter=$IFACE not found" | logger -t shadow-shield
    exit 1
fi

gen_mac() {
    local first=$(( (RANDOM % 256) & 0xFC | 0x02 ))
    printf '%02X' "$first"
    for _ in 1 2 3 4 5; do
        printf ':%02X' $(( RANDOM % 256 ))
    done
}

NEW_MAC="$(gen_mac)"

hciconfig "$IFACE" down
btmgmt -i "$IFACE" public-addr "$NEW_MAC" >/dev/null 2>&1
hciconfig "$IFACE" up
sleep 1

ACTUAL_MAC="$(hciconfig "$IFACE" | grep -oP 'BD Address:\s*\K\S+')"

if [ "$ACTUAL_MAC" = "$NEW_MAC" ]; then
    msg="HARDEN(boot) bt-mac-spoof OK adapter=$IFACE mac=$ACTUAL_MAC"
else
    msg="HARDEN(boot) bt-mac-spoof NOT APPLIED adapter=$IFACE requested=$NEW_MAC actual=$ACTUAL_MAC (chipset likely ignored public-addr)"
fi
echo "$msg"
logger -t shadow-shield "$msg" 2>/dev/null
