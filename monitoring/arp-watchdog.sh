#!/bin/bash
# Shadow_Shield — ARP Spoof Detection
# Auto-detects gateway on any network, alerts on MAC changes

LOGFILE="/var/log/arp-watchdog.log"
KNOWN_MAC=""
GATEWAY_IP=""

while true; do
    # Auto-detect current gateway
    NEW_GW=$(ip route | awk '/default via/{print $3; exit}')

    # If gateway changed (switched networks), reset known MAC
    if [ "$NEW_GW" != "$GATEWAY_IP" ]; then
        GATEWAY_IP="$NEW_GW"
        KNOWN_MAC=""
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Gateway changed to $GATEWAY_IP — learning MAC" >> "$LOGFILE"
    fi

    if [ -z "$GATEWAY_IP" ]; then
        sleep 30
        continue
    fi

    CURRENT_MAC=$(arp -n "$GATEWAY_IP" 2>/dev/null | awk '/ether/{print $3}')

    if [ -z "$CURRENT_MAC" ]; then
        sleep 30
        continue
    fi

    # First time seeing this gateway — learn its MAC
    if [ -z "$KNOWN_MAC" ]; then
        KNOWN_MAC="$CURRENT_MAC"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Learned gateway $GATEWAY_IP MAC: $KNOWN_MAC" >> "$LOGFILE"
    elif [ "$CURRENT_MAC" != "$KNOWN_MAC" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [ALERT] ARP SPOOF DETECTED! Gateway $GATEWAY_IP MAC changed: $KNOWN_MAC -> $CURRENT_MAC" >> "$LOGFILE"
        logger -p auth.crit "ARP SPOOF: Gateway $GATEWAY_IP MAC changed from $KNOWN_MAC to $CURRENT_MAC"
    fi

    sleep 30
done
