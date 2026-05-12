#!/bin/bash
# Shadow_Shield — Safe Kismet Launcher
# Starts monitor mode on wlan1 without killing NetworkManager

INTERFACE="wlan1"

echo "--- SHADOW_SHIELD: SAFE KISMET START ---"

# 1. Tell NetworkManager to ignore this specific card
echo "[*] Ensuring NetworkManager ignores $INTERFACE..."
sudo nmcli device set $INTERFACE managed no

# 2. Reset the interface to be safe
echo "[*] Resetting $INTERFACE..."
sudo ip link set $INTERFACE down
sudo iw dev $INTERFACE set type managed
sudo ip link set $INTERFACE up
sleep 1
sudo ip link set $INTERFACE down

# 3. Enable Monitor Mode manually (avoiding airmon-ng check kill)
echo "[*] Enabling Monitor Mode on $INTERFACE..."
sudo iw dev $INTERFACE set type monitor
sudo ip link set $INTERFACE up

# 4. Verify
MODE=$(iw dev $INTERFACE info 2>/dev/null | grep type | awk '{print $2}')
if [ "$MODE" == "monitor" ]; then
    echo "[✓] SUCCESS: $INTERFACE is now in MONITOR mode."

    # Check if Kismet is already running
    if pgrep -x kismet > /dev/null; then
        echo "[!] Kismet already running. Killing old instance..."
        sudo pkill -9 kismet 2>/dev/null
        sleep 2
    fi

    echo "[*] Launching Kismet in the background..."
    sudo kismet -d 2>/dev/null &
    sleep 3

    if pgrep -x kismet > /dev/null; then
        echo "[✓] Kismet started successfully."
        echo ""
        echo "--- SETUP COMPLETE ---"
        echo "Kismet is running. Access the UI at: http://localhost:2501"
        echo "Your main network (wlan0) should still be connected."
    else
        echo "[!] ERROR: Kismet failed to start. Check permissions."
        exit 1
    fi
else
    echo "[!] ERROR: Failed to set monitor mode on $INTERFACE."
    echo "[!] Try: sudo iw phy phy1 set regulatory.custom_regulatory true"
    exit 1
fi
