#!/bin/bash
# Shadow_Shield — Security Dashboard
# One command to check all evidence sources

echo "=========================================="
echo "  SHADOW_SHIELD SECURITY CHECK — $(date '+%Y-%m-%d %H:%M')"
echo "=========================================="

echo ""
echo "[1] FIREWALL DROPS (inbound probes)"
echo "---"
DROPS=$(journalctl -k -g "nft-in-drop" --since "24 hours ago" --no-pager 2>/dev/null | grep -c "nft-in-drop")
echo "  Last 24h: $DROPS blocked packets"
journalctl -k -g "nft-in-drop" --since "24 hours ago" --no-pager 2>/dev/null | tail -5

echo ""
echo "[2] OUTBOUND BLOCKS (kill-switch catches)"
echo "---"
OUT_DROPS=$(journalctl -k -g "nft-out-drop" --since "24 hours ago" --no-pager 2>/dev/null | grep -c "nft-out-drop")
echo "  Last 24h: $OUT_DROPS blocked outbound packets"
journalctl -k -g "nft-out-drop" --since "24 hours ago" --no-pager 2>/dev/null | tail -5

echo ""
echo "[3] ARP SPOOF ALERTS"
echo "---"
if [ -f /var/log/arp-watchdog.log ]; then
    ALERTS=$(grep -c "ALERT" /var/log/arp-watchdog.log 2>/dev/null)
    echo "  Total alerts: ${ALERTS:-0}"
    # Extract the attacker's MAC and try to identify the hardware vendor
    grep "ALERT" /var/log/arp-watchdog.log 2>/dev/null | tail -5 | while read -r line; do
        ATTACK_MAC=$(echo "$line" | grep -oE "([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}" | tail -1)
        OUI=$(echo "$ATTACK_MAC" | tr -d ':' | cut -c1-6 | tr '[:lower:]' '[:upper:]')
        VENDOR=$(grep -i "^$OUI" /usr/share/nmap/nmap-mac-prefixes 2>/dev/null | cut -f2-)
        echo "  $line"
        [ -n "$VENDOR" ] && echo "    └─ Hardware Identity: $VENDOR" || echo "    └─ Hardware Identity: Unknown Vendor"
    done
else
    echo "  No alerts (clean)"
fi

echo ""
echo "[4] TOP NETWORK PROBES (Attacker IPs)"
echo "---"
journalctl -k -g "nft-in-drop" --since "24 hours ago" --no-pager 2>/dev/null | grep -oE "SRC=[0-9.]+" | cut -d= -f2 | sort | uniq -c | sort -rn | head -5 | while read -r count ip; do
    echo "  $count attempts from $ip"
done

echo ""
echo "[5] EVIL TWIN & MITM SIGNATURES"
echo "---"
# Use the most recent Kismet DB for live forensics
LATEST_DB=$(ls -t /home/shadowed/Kismet-*.kismet 2>/dev/null | head -n 1)
if [ -n "$LATEST_DB" ]; then
    # 1. Detection of MAC Clusters (BSSID Spoofing/Pineapple)
    # Checks for MACs sharing the same last 3 octets (common in Virtual APs)
    CLUSTERS=$(sqlite3 "$LATEST_DB" "SELECT substr(devmac, 10, 8) as suffix, count(*) as c FROM devices GROUP BY suffix HAVING c > 2 ORDER BY c DESC LIMIT 1;" 2>/dev/null)
    if [ -n "$CLUSTERS" ]; then
        SUFFIX=$(echo "$CLUSTERS" | cut -d'|' -f1)
        COUNT=$(echo "$CLUSTERS" | cut -d'|' -f2)
        echo "  [!] ALERT: MAC Cluster Detected ($COUNT devices ending in ...$SUFFIX)"
        echo "      Signature: Potential WiFi Pineapple or Rogue AP Spoofer."
    fi

    # 2. Deauth Flood Detection
    DEAUTHS=$(sqlite3 "$LATEST_DB" "SELECT count(*) FROM alerts WHERE header LIKE '%DEAUTH%';" 2>/dev/null)
    if [ "$DEAUTHS" -gt 0 ]; then
        echo "  [!] ALERT: $DEAUTHS Deauthentication events found in Kismet logs."
        echo "      Signature: Active attempt to kick clients from secure Wi-Fi."
    fi

    # 3. High Proximity Detection
    PROXIMITY=$(sqlite3 "$LATEST_DB" "SELECT devmac FROM devices WHERE strongest_signal > -25 AND type != 'dot11_ap' LIMIT 1;" 2>/dev/null)
    if [ -n "$PROXIMITY" ]; then
        echo "  [!] WARNING: High Proximity Device Detected ($PROXIMITY)"
        echo "      Signal is > -25dBm. Attacker may be within 5-10 feet."
    fi
else
    echo "  Kismet database not found (skipped)"
fi

echo ""
echo "[6] GATEWAY INTEGRITY"
echo "---"
CURRENT_GW_IP=$(ip route | awk '/default via/{print $3; exit}')
CURRENT_GW_MAC=$(arp -n "$CURRENT_GW_IP" 2>/dev/null | awk '/ether/{print $3}')
if [ -f /var/log/arp-watchdog.log ]; then
    LEARNED_MAC=$(grep "Learned gateway $CURRENT_GW_IP" /var/log/arp-watchdog.log | tail -1 | awk '{print $NF}')
    if [ -n "$CURRENT_GW_MAC" ] && [ -n "$LEARNED_MAC" ] && [ "$CURRENT_GW_MAC" != "$LEARNED_MAC" ]; then
        echo "  [!!!] CRITICAL: Current Gateway MAC ($CURRENT_GW_MAC) DOES NOT MATCH learned MAC ($LEARNED_MAC)!"
    else
        echo "  Gateway IP $CURRENT_GW_IP verified: MAC $CURRENT_GW_MAC matches learned state."
    fi
fi

echo ""
echo "[7] CREDENTIAL FILE ACCESS"
echo "---"
ausearch -k cred_ssh -k cred_claude -k cred_github -k cred_secrets -k cred_gpg --start today 2>/dev/null | grep -c "type=SYSCALL"
echo "  access events today"
ausearch -k cred_ssh -k cred_claude -k cred_github -k cred_secrets --start today 2>/dev/null | grep "exe=" | sort -u | tail -10

echo ""
echo "[8] PRIVILEGE ESCALATION"
echo "---"
ausearch -k priv_sudo -k priv_su -k priv_pkexec --start today 2>/dev/null | grep "exe=" | awk -F'exe=' '{print $2}' | sort | uniq -c | sort -rn | head -5

echo ""
echo "[9] KERNEL MODULES LOADED"
echo "---"
ausearch -k kernel_module --start today 2>/dev/null | grep -c "type=SYSCALL"
echo "  module load events today"

echo ""
echo "[10] FAILED LOGINS"
echo "---"
journalctl -u sshd --since "24 hours ago" --no-pager 2>/dev/null | grep -i "failed\|invalid" | tail -5
echo "  $(journalctl -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'failed\|invalid') failed SSH attempts"

echo ""
echo "[11] VPN STATUS"

echo "---"
if ip link show wg-US-FREE-96 &>/dev/null; then
    echo "  WireGuard: UP"
    wg show wg-US-FREE-96 2>/dev/null | grep "latest handshake"
else
    echo "  WireGuard: DOWN — EXPOSED!"
fi

echo ""
echo "=========================================="
