#!/bin/bash
# Shadow_Shield — Kismet Lockdown Launcher
# Forces monitor mode and detects interface name

INTERFACE="wlan1"
MON_INTERFACE="wlan1mon"

echo "[*] Lockdown: Ensuring NetworkManager ignores $INTERFACE..."
sudo nmcli device set $INTERFACE managed no

echo "[*] Lockdown: Resetting $INTERFACE..."
sudo ip link set $INTERFACE down
sudo iw dev $INTERFACE set type managed 2>/dev/null
sudo ip link set $INTERFACE up
sleep 1
sudo ip link set $INTERFACE down

echo "[*] Lockdown: Forcing monitor mode..."
sudo iw dev $INTERFACE set type monitor
sudo ip link set $INTERFACE up

# Detect if airmon-ng created a virtual monitor interface
if ip link show $MON_INTERFACE >/dev/null 2>&1; then
    TARGET=$MON_INTERFACE
else
    TARGET=$INTERFACE
fi

echo "[*] Lockdown: Checking mode on $TARGET..."
MODE=$(iw dev $TARGET info 2>/dev/null | grep type | awk '{print $2}')

if [ "$MODE" == "monitor" ]; then
    echo "[✓] Monitor mode confirmed on $TARGET."
    echo "[*] Launching Kismet in lockdown mode..."

    # Kill any "ghost" processes left over
    sudo pkill -9 kismet 2>/dev/null
    sleep 2

    # Start Kismet as daemon (it auto-detects monitor interfaces)
    sudo kismet -d 2>/dev/null &

    sleep 3
    if pgrep -x "kismet" > /dev/null; then
        echo "[✓] SUCCESS: Kismet is running on $TARGET."
        echo "[*] Web UI: http://localhost:2501"
    else
        echo "[!] ERROR: Kismet failed to start."
        echo "[!] Verify: sudo iw dev $TARGET info"
        exit 1
    fi
else
    echo "[!] CRITICAL: Failed to hold monitor mode on $TARGET."
    echo "[!] Diagnosis:"
    echo "    iw dev $TARGET info"
    echo "    or try replugging the adapter."
    exit 1
fi
