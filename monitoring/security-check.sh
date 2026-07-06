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
echo "[3] ARP GATEWAY EVENTS (last 24h)"
echo "---"
if [ -f /var/log/arp-watchdog.log ]; then
    SINCE=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S')
    ALERTS=$(awk -v s="$SINCE" '$0~/\[ALERT\]/{if ($1" "$2>=s) n++} END{print n+0}' /var/log/arp-watchdog.log 2>/dev/null)
    WARNS=$(awk -v s="$SINCE" '$0~/\[WARN\]/{if ($1" "$2>=s) n++} END{print n+0}' /var/log/arp-watchdog.log 2>/dev/null)
    echo "  Last 24h: ${ALERTS:-0} flap alerts, ${WARNS:-0} MAC-change warnings"
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
echo "[4] TOP DROPPED-PACKET SOURCES (probes/noise)"
echo "---"
journalctl -k -g "nft-in-drop" --since "24 hours ago" --no-pager 2>/dev/null | grep -oE "SRC=[0-9.]+" | cut -d= -f2 | sort | uniq -c | sort -rn | head -5 | while read -r count ip; do
    echo "  $count attempts from $ip"
done

echo ""
echo "[5] EVIL TWIN & MITM SIGNATURES"
echo "---"
# Use the most recent Kismet DB for live forensics
LATEST_DB=$(find __HOME_DIR__ /root -name "Kismet-*.kismet" -type f 2>/dev/null | sort -V | tail -n 1)
if [ -n "$LATEST_DB" ] && [ -f "$LATEST_DB" ]; then
    # Verify DB is accessible and not locked (live captures hold the lock)
    if ! sqlite3 "file:$LATEST_DB?mode=ro" "SELECT 1 LIMIT 1;" >/dev/null 2>&1; then
        echo "  Kismet database is locked by a live capture (skipped — normal while Kismet runs)"
    else
        # NOTE (v2): the original three queries here referenced columns that
        # don't exist in Kismet's schema (mac, signal_dbm, ts, type on packets)
        # so they silently never ran. Rewritten against the real schema:
        # devices(devmac, type, strongest_signal, last_time), packets(ts_sec).

        # 1. Same-SSID/BSSID density sanity check — REMOVED as unreliable.
        # "Many APs sharing an OUI" is normal (neighborhoods full of the same
        # ISP router brand) and flags nothing actionable. Evil-twin detection
        # needs SSID comparison, which lives in the device BLOB, not a column.
        # Use Kismet's own built-in alerts (UI: Alerts panel) for this.

        # 2. Strong-signal non-AP devices seen in the last 10 minutes.
        # Factual reporting only: strong signal = physically near. That is
        # usually YOUR OWN phone/watch/headphones or a neighbor through a wall.
        NOW=$(date +%s)
        CLOSE=$(sqlite3 "file:$LATEST_DB?mode=ro" \
          "SELECT COUNT(*) FROM devices WHERE strongest_signal > -40 AND strongest_signal < 0 AND type NOT LIKE '%AP%' AND last_time > $((NOW - 600));" 2>/dev/null)
        if [ -n "$CLOSE" ] && [ "$CLOSE" -gt 0 ]; then
            echo "  $CLOSE non-AP device(s) with strong signal (>-40dBm) in last 10 min"
            echo "      Note: likely your own devices or close neighbors. Cross-check"
            echo "      MACs in Kismet UI before reading anything into this."
        else
            echo "  No strong-signal non-AP devices in last 10 min"
        fi

        # 3. Packet-rate sanity (last 10 min), scaled per active source.
        # The old check flagged >5000 'beacons'/10min — but ONE healthy AP
        # beacons ~6000/10min, so that would have flagged every WiFi
        # environment on Earth. Report rate factually instead.
        PKTS=$(sqlite3 "file:$LATEST_DB?mode=ro" \
          "SELECT COUNT(*) FROM packets WHERE ts_sec > $((NOW - 600));" 2>/dev/null)
        SRCS=$(sqlite3 "file:$LATEST_DB?mode=ro" \
          "SELECT COUNT(DISTINCT sourcemac) FROM packets WHERE ts_sec > $((NOW - 600));" 2>/dev/null)
        if [ -n "$PKTS" ] && [ "$PKTS" -gt 0 ]; then
            echo "  Capture rate: $PKTS packets / ${SRCS:-?} sources in last 10 min"
        else
            echo "  No packets in last 10 min (capture idle or DB settled)"
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
    CURRENT_GW_MAC=$(ip neigh show "$CURRENT_GW_IP" 2>/dev/null | awk '/lladdr/{print $5; exit}')
    if [ -f /var/log/arp-watchdog.log ]; then
        # v2 fix: v1 grepped "Learned gateway" but the watchdog logs
        # "Learned MAC for" — the pattern never matched, so this check was
        # dead AND claimed "verified" anyway. Match the real format:
        LEARNED_MAC=$(grep "Learned MAC for $CURRENT_GW_IP" /var/log/arp-watchdog.log 2>/dev/null | tail -1 | awk '{print $NF}')
        if [ -z "$LEARNED_MAC" ]; then
            echo "  Gateway $CURRENT_GW_IP: $CURRENT_GW_MAC (no learned baseline yet — NOT verified)"
        elif [ -n "$CURRENT_GW_MAC" ] && [ "$CURRENT_GW_MAC" != "$LEARNED_MAC" ]; then
            echo "  [!] Gateway MAC differs from learned baseline:"
            echo "       Current: $CURRENT_GW_MAC"
            echo "       Learned: $LEARNED_MAC"
            echo "       Could be ARP poisoning OR a legit router/mesh change —"
            echo "       check the watchdog log for flap alerts before concluding."
        else
            echo "  Gateway $CURRENT_GW_IP verified: MAC $CURRENT_GW_MAC matches learned baseline"
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
if ip link show __WG_IFACE__ &>/dev/null; then
    echo "  WireGuard: UP"
    wg show __WG_IFACE__ 2>/dev/null | grep "latest handshake"
else
    echo "  WireGuard: DOWN — EXPOSED!"
fi

echo ""
echo "=========================================="
