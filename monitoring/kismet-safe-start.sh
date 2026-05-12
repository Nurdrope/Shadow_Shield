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
MODE=$(iw dev $INTERFACE info | grep type | awk '{print $2}')
if [ "$MODE" == "monitor" ]; then
    echo "[✓] SUCCESS: $INTERFACE is now in MONITOR mode."
    echo "[*] Launching Kismet in the background..."
    # We use --no-auto-log to keep things clean as requested before
    sudo kismet -i $INTERFACE --no-auto-log &
    echo ""
    echo "--- SETUP COMPLETE ---"
    echo "Kismet is running. Access the UI at: http://localhost:2501"
    echo "Your main network (wlan0) should still be connected."
else
    echo "[!] ERROR: Failed to set monitor mode. You may need to replug the card."
fi
