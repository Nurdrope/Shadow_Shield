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
    grep "ALERT" /var/log/arp-watchdog.log 2>/dev/null | tail -5
else
    echo "  No alerts (clean)"
fi

echo ""
echo "[4] CREDENTIAL FILE ACCESS"
echo "---"
ausearch -k cred_ssh -k cred_claude -k cred_github -k cred_secrets -k cred_gpg --start today 2>/dev/null | grep -c "type=SYSCALL"
echo "  access events today"
ausearch -k cred_ssh -k cred_claude -k cred_github -k cred_secrets --start today 2>/dev/null | grep "exe=" | sort -u | tail -10

echo ""
echo "[5] PRIVILEGE ESCALATION"
echo "---"
ausearch -k priv_sudo -k priv_su -k priv_pkexec --start today 2>/dev/null | grep "exe=" | awk -F'exe=' '{print $2}' | sort | uniq -c | sort -rn | head -5

echo ""
echo "[6] KERNEL MODULES LOADED"
echo "---"
ausearch -k kernel_module --start today 2>/dev/null | grep -c "type=SYSCALL"
echo "  module load events today"

echo ""
echo "[7] FAILED LOGINS"
echo "---"
journalctl -u sshd --since "24 hours ago" --no-pager 2>/dev/null | grep -i "failed\|invalid" | tail -5
echo "  $(journalctl -u sshd --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'failed\|invalid') failed SSH attempts"

echo ""
echo "[8] VPN STATUS"
echo "---"
if ip link show wg-US-FREE-96 &>/dev/null; then
    echo "  WireGuard: UP"
    wg show wg-US-FREE-96 2>/dev/null | grep "latest handshake"
else
    echo "  WireGuard: DOWN — EXPOSED!"
fi

echo ""
echo "=========================================="
