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
LATEST_DB=$(find /home/shadowed /root -name "Kismet-*.kismet" -type f 2>/dev/null | sort -V | tail -n 1)
if [ -n "$LATEST_DB" ] && [ -f "$LATEST_DB" ]; then
    # Verify DB is accessible and not locked
    if ! sqlite3 "$LATEST_DB" "SELECT 1 LIMIT 1;" >/dev/null 2>&1; then
        echo "  Kismet database is locked or corrupted (skipped)"
    else
        # 1. Detection of MAC Clusters (BSSID Spoofing/Pineapple)
        # Look for multiple APs with same OUI prefix (suspicious pattern)
        CLUSTERS=$(sqlite3 "$LATEST_DB" "SELECT substr(mac, 1, 8) as oui, COUNT(*) as cnt FROM devices WHERE type LIKE '%AP%' GROUP BY oui HAVING cnt > 3 ORDER BY cnt DESC LIMIT 1;" 2>/dev/null)
        if [ -n "$CLUSTERS" ]; then
            OUI=$(echo "$CLUSTERS" | cut -d'|' -f1)
            COUNT=$(echo "$CLUSTERS" | cut -d'|' -f2)
            echo "  [!] ALERT: MAC Cluster Detected ($COUNT APs with OUI $OUI)"
            echo "      Signature: Possible WiFi Pineapple or Evil Twin network."
        fi

        # 2. Strong Signal Proximity Detection (hostile device very close)
        CLOSE=$(sqlite3 "$LATEST_DB" "SELECT COUNT(*) FROM devices WHERE signal_dbm > -40 AND type NOT LIKE '%AP%';" 2>/dev/null)
        if [ "$CLOSE" -gt 0 ]; then
            echo "  [!] WARNING: $CLOSE devices with strong signal (> -40dBm)"
            echo "      Attacker may be within 10-20 feet (very close)."
        fi

        # 3. Check for massive beacon storms (signature of rogue AP)
        BEACONS=$(sqlite3 "$LATEST_DB" "SELECT COUNT(*) FROM packets WHERE type LIKE '%beacon%' AND ts > datetime('now', '-10 minutes');" 2>/dev/null)
        if [ "$BEACONS" -gt 5000 ]; then
            echo "  [!] ALERT: Beacon storm detected ($BEACONS in 10 min)"
            echo "      Signature: Possible rogue or misconfigured AP flooding network."
        fi
    fi
else
    echo "  Kismet database not found (skipped)"
fi

echo ""
echo "[6] GATEWAY INTEGRITY"
echo "---"
CURRENT_GW_IP=$(ip route | awk '/default via/{print $3; exit}')
if [ -z "$CURRENT_GW_IP" ]; then
    echo "  No default gateway (VPN kill-switch active?)"
else
    CURRENT_GW_MAC=$(arp -n "$CURRENT_GW_IP" 2>/dev/null | awk '/ether/{print $3}')
    if [ -f /var/log/arp-watchdog.log ]; then
        LEARNED_MAC=$(grep "Learned gateway $CURRENT_GW_IP" /var/log/arp-watchdog.log | tail -1 | awk '{print $NF}' | tr -d '[]')
        if [ -n "$CURRENT_GW_MAC" ] && [ -n "$LEARNED_MAC" ] && [ "$CURRENT_GW_MAC" != "$LEARNED_MAC" ]; then
            echo "  [!!!] CRITICAL: Gateway MAC mismatch!"
            echo "       Current: $CURRENT_GW_MAC"
            echo "       Learned: $LEARNED_MAC"
            echo "       POSSIBLE ARP POISONING ATTACK"
        else
            echo "  Gateway $CURRENT_GW_IP verified: MAC $CURRENT_GW_MAC (learned)"
        fi
    else
        echo "  ARP watchdog log not found. Gateway $CURRENT_GW_IP: $CURRENT_GW_MAC"
    fi
fi

echo ""
echo "[7] CREDENTIAL FILE ACCESS"
echo "---"
CRED_ACCESSES=$(ausearch -k cred_access --start today 2>/dev/null | grep -c "type=SYSCALL")
if [ -n "$CRED_ACCESSES" ] && [ "$CRED_ACCESSES" -gt 0 ]; then
    echo "  $CRED_ACCESSES credential file access events today"
    ausearch -k cred_access --start today 2>/dev/null | grep "exe=" | awk -F'exe=' '{print $2}' | sort | uniq -c | sort -rn | head -5
else
    echo "  No credential file access detected (clean)"
fi

echo ""
echo "[8] PRIVILEGE ESCALATION"
echo "---"
PRIV_EVENTS=$(ausearch -k priv_escalation --start today 2>/dev/null | grep -c "type=SYSCALL")
if [ -n "$PRIV_EVENTS" ] && [ "$PRIV_EVENTS" -gt 0 ]; then
    echo "  $PRIV_EVENTS privilege escalation events today:"
    ausearch -k priv_escalation --start today 2>/dev/null | grep "exe=" | awk -F'exe=' '{print $2}' | sort | uniq -c | sort -rn | head -5
else
    echo "  No privilege escalation events (clean)"
fi

echo ""
echo "[9] KERNEL MODULES LOADED"
echo "---"
MODULE_LOADS=$(ausearch -k kernel_module --start today 2>/dev/null | grep -c "type=SYSCALL")
if [ "$MODULE_LOADS" -gt 0 ]; then
    echo "  [!] $MODULE_LOADS kernel module load events today"
    ausearch -k kernel_module --start today 2>/dev/null | grep "name=" | awk -F'name=' '{print $2}' | sort -u | head -10
else
    echo "  No kernel module loads today (clean)"
fi

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
