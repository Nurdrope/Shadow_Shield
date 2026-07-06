#!/bin/bash
# Shadow_Shield — XFCE Panel Security Indicator v2
# For xfce4-genmon-plugin, period 30s.
# Honest by design: alerts are time-windowed (stale drama expires) and
# routine firewall noise is not an emergency.

ALERT=""

# VPN check (interface substituted by install.sh)
WG_IFACE="__WG_IFACE__"
if ip link show "$WG_IFACE" &>/dev/null; then
    VPN="VPN:ON"
else
    VPN="VPN:OFF"
    ALERT="!"
fi

# ARP alerts — only count events from the last 24h (v1 grepped the whole
# log history, so one stale alert kept the panel red forever)
ARP="ARP:OK"
if [ -r /var/log/arp-watchdog.log ]; then
    SINCE=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')
    RECENT_ALERTS=$(awk -v since="$SINCE" \
        '$0 ~ /\[ALERT\]/ { ts=$1" "$2; if (ts >= since) n++ } END{print n+0}' \
        /var/log/arp-watchdog.log 2>/dev/null)
    if [ "${RECENT_ALERTS:-0}" -gt 0 ]; then
        ARP="ARP:${RECENT_ALERTS}"
        ALERT="!"
    fi
fi

# Firewall drops last hour — informational. Drops mean the firewall is
# WORKING. Only escalate on an unusual flood.
DROP_FLOOD=200
DROPS=$(journalctl -k -g "nft-in-drop" --since "1 hour ago" --no-pager 2>/dev/null | grep -c "nft-in-drop")
if [ -z "$DROPS" ]; then
    FW="FW:?"          # journal unreadable — say so, don't fake a zero
elif [ "$DROPS" -gt "$DROP_FLOOD" ]; then
    FW="FW:${DROPS}!"
    ALERT="!"
else
    FW="FW:${DROPS}"
fi

# Failed SSH in last hour (informational)
SSH_FAIL=$(journalctl -u ssh -u sshd --since "1 hour ago" --no-pager 2>/dev/null | grep -ci "failed\|invalid")

TIPS="$VPN | $ARP | Drops(1h):${DROPS:-?} | SSH-fail:${SSH_FAIL:-?}"

if [ -n "$ALERT" ]; then
    echo "<txt><span foreground='red' weight='bold'>SEC</span></txt>"
else
    echo "<txt><span foreground='#00ff00' weight='bold'>SEC</span></txt>"
fi
echo "<tool>$TIPS</tool>"
echo "<click>xfce4-terminal -e 'bash -c \"sudo /usr/local/bin/security-check.sh; read -p \\\"[enter to close]\\\"\"'</click>"
