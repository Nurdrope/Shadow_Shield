#!/bin/bash
# Shadow_Shield — XFCE Panel Security Indicator
# For use with xfce4-genmon-plugin (Generic Monitor)
# Set command to this script, period to 30 seconds

ALERT=""

# VPN check (CONFIGURE: replace with your WireGuard interface)
WG_IFACE="wg-US-FREE-96"
if ip link show "$WG_IFACE" &>/dev/null; then
    VPN="VPN:ON"
else
    VPN="VPN:OFF"
    ALERT="!"
fi

# ARP spoof check
if [ -f /var/log/arp-watchdog.log ] && grep -q "ALERT" /var/log/arp-watchdog.log 2>/dev/null; then
    ARP="ARP:SPOOF"
    ALERT="!"
else
    ARP="ARP:OK"
fi

# Firewall drops in last hour
DROPS=$(journalctl -k -g "nft-in-drop" --since "1 hour ago" --no-pager 2>/dev/null | grep -c "nft-in-drop" 2>/dev/null)
if [ "$DROPS" -gt 0 ] 2>/dev/null; then
    FW="FW:${DROPS}"
    ALERT="!"
else
    FW="FW:0"
fi

# Failed SSH in last hour
SSH_FAIL=$(journalctl -u sshd --since "1 hour ago" --no-pager 2>/dev/null | grep -ci "failed\|invalid" 2>/dev/null)

# Build tooltip
TIPS="$VPN | $ARP | Drops:$DROPS | SSH-fail:$SSH_FAIL"

# Display
if [ -n "$ALERT" ]; then
    echo "<txt><span foreground='red' weight='bold'>SEC</span></txt>"
else
    echo "<txt><span foreground='#00ff00' weight='bold'>SEC</span></txt>"
fi
echo "<tool>$TIPS</tool>"
echo "<click>/usr/local/bin/security-check.sh</click>"
