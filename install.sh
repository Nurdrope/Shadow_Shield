#!/bin/bash
# Shadow_Shield Installer
# Tested on Kali Linux / Debian-based systems
#
# BEFORE RUNNING: Review and customize configs for your setup
# - firewall/nftables.conf: Set your WireGuard interface name and fwmark
# - monitoring/evidence.rules: Set your home directory path
# - monitoring/security-panel.sh: Set your WireGuard interface name

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

echo "=== Shadow_Shield Installer ==="
echo ""

# Required packages
echo "[1/7] Installing dependencies..."
apt install -y nftables auditd fail2ban xfce4-genmon-plugin 2>/dev/null || true

# Kernel hardening
echo "[2/7] Applying kernel hardening..."
cp kernel/99-hardening.conf /etc/sysctl.d/
cp kernel/disable-protocols.conf /etc/modprobe.d/
sysctl --system > /dev/null 2>&1

# Firewall
echo "[3/7] Installing firewall with VPN kill-switch..."
cp /etc/nftables.conf /etc/nftables.conf.bak 2>/dev/null || true
cp firewall/nftables.conf /etc/nftables.conf
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
systemctl enable nftables

# Privacy
echo "[4/7] Configuring network privacy..."
cp privacy/00-privacy.conf /etc/NetworkManager/conf.d/
systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true

# Monitoring scripts
echo "[5/7] Installing monitoring tools..."
cp monitoring/arp-watchdog.sh /usr/local/bin/
cp monitoring/security-check.sh /usr/local/bin/
cp monitoring/security-panel.sh /usr/local/bin/
chmod 755 /usr/local/bin/arp-watchdog.sh
chmod 755 /usr/local/bin/security-check.sh
chmod 755 /usr/local/bin/security-panel.sh

# ARP watchdog service
echo "[6/7] Enabling ARP spoof detection..."
cp monitoring/arp-watchdog.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now arp-watchdog.service

# Audit rules
echo "[7/7] Loading forensic audit rules..."
cp monitoring/evidence.rules /etc/audit/rules.d/
auditctl -R monitoring/evidence.rules 2>/dev/null || true

echo ""
echo "=== Shadow_Shield Installed ==="
echo ""
echo "Next steps:"
echo "  1. Review /etc/nftables.conf — set your WireGuard interface name"
echo "  2. Enable VPN auto-start: sudo systemctl enable wg-quick@YOUR-WG-INTERFACE"
echo "  3. Restart NetworkManager: sudo systemctl restart NetworkManager"
echo "  4. Add Generic Monitor to XFCE panel:"
echo "     Command: /usr/local/bin/security-panel.sh"
echo "     Period: 30 seconds"
echo "  5. Run security check: sudo /usr/local/bin/security-check.sh"
echo ""
echo "Stay ghost. Stay safe."
