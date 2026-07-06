# Shadow_Shield

Linux security hardening + network privacy + real-time intrusion detection for hostile shared networks.

Built for people who need to stay safe on networks they don't control — shelters, cafes, libraries, shared housing. Designed for Debian/Kali Linux with WireGuard VPN.

## What it does

### Firewall + VPN Kill-Switch
- Default-deny inbound firewall (nftables)
- **VPN kill-switch**: if WireGuard drops, ALL internet traffic stops — zero leaks
- Portable across any network (captive portals, any private subnet)

### Kernel Hardening
- 17 sysctl hardening values (ptrace, BPF, ICMP redirects, dmesg, etc.)
- Disabled unnecessary protocols (DCCP, SCTP, RDS, TIPC)

### Network Privacy
- **MAC randomization**: stable fake MAC per WiFi network (no captive portal friction)
- **Hostname hidden**: DHCP never sends your machine name
- **mDNS/Avahi disabled**: no local service broadcasts
- **IPv6 privacy extensions**: random temporary addresses

### Intrusion Detection
- **ARP spoof watchdog**: auto-detects gateway, alerts if MAC changes (MITM detection)
- **27 auditd rules**: logs process execution, credential access, privilege escalation, kernel modules, network connections, config tampering
- **Security dashboard**: single command to review all evidence sources
- **XFCE panel indicator**: real-time green/red security status next to your clock

## Quick Start

```bash
git clone https://github.com/Nurdrope/Shadow_Shield.git
cd Shadow_Shield

# See exactly what it will do — changes nothing:
sudo ./install.sh --dry-run

# Install (auto-detects your WireGuard interface — no manual editing):
sudo ./install.sh
```

The installer is **safe by default**:

- **Auto-detects** your WireGuard interface and fwmark — no config editing.
- **Won't lock you out.** If no live tunnel is found, it refuses to install the
  outbound kill-switch (which would drop all your internet) and offers an
  inbound-only firewall instead.
- **Auto-revert.** The kill-switch is applied on a timer and rolls back
  automatically unless you confirm you still have connectivity — the same
  anti-lockout trick used for remote firewall changes over SSH.
- **Reversible.** Every overwritten file is backed up to
  `/var/backups/shadow_shield/`, and an uninstaller is written to
  `/usr/local/sbin/shadow_shield-uninstall.sh`.

```bash
# Useful flags:
sudo ./install.sh --no-killswitch          # inbound firewall only
sudo ./install.sh --iface wg0              # force a specific interface
sudo ./install.sh --yes                    # non-interactive (uses a real
                                           #   connectivity self-test to confirm)
sudo ./install.sh --revert-timeout 120     # seconds before auto-revert
```

## File Structure

```
Shadow_Shield/
├── install.sh                      # One-command installer
├── firewall/
│   └── nftables.conf               # VPN kill-switch firewall
├── kernel/
│   ├── 99-hardening.conf           # sysctl hardening values
│   └── disable-protocols.conf      # Block unnecessary protocols
├── monitoring/
│   ├── arp-watchdog.sh             # ARP spoof detection daemon
│   ├── arp-watchdog.service        # systemd service for watchdog
│   ├── evidence.rules              # auditd forensic rules
│   ├── kismet-safe-start.sh        # Safe Kismet launcher (monitor mode)
│   ├── security-check.sh           # Full security dashboard
│   └── security-panel.sh           # XFCE panel indicator
└── privacy/
    └── 00-privacy.conf             # NetworkManager MAC/hostname privacy
```

## Security Dashboard

Run anytime to check for suspicious activity:

```bash
sudo /usr/local/bin/security-check.sh
```

Shows:
- Firewall drops (port scans, probes)
- Kill-switch blocks (VPN leak attempts)
- ARP spoof alerts (MITM attacks)
- **Evil Twin & MITM Signatures** (New: MAC Clusters & Deauth Floods)
- **Proximity Detection** (New: Alerts on high-signal attackers)
- Credential file access (unauthorized reads)
- Privilege escalation events
- Kernel module loads (rootkit detection)
- Failed SSH logins
- VPN status

## Panel Indicator

Add to XFCE panel via Generic Monitor plugin:
- **Command**: `/usr/local/bin/security-panel.sh`
- **Period**: 30 seconds

Green = all clear. Red = something needs attention. Hover for details.

## Wireless Reconnaissance (Kismet)

Launch wireless network monitoring without killing your main connection:

```bash
# Safe mode: NetworkManager ignores wlan1, main network stays up
sudo /usr/local/bin/kismet-safe-start.sh

# Lockdown mode: Aggressive monitor mode, better for hostile environments
sudo /usr/local/bin/kismet-lockdown.sh
```

Access the Kismet web UI at: `http://localhost:2501`

The security dashboard automatically detects Evil Twin and MITM signatures from Kismet's database:
- MAC clustering (Pineapple detection)
- Deauth floods (active attacks)
- Beacon storms (rogue AP overload)
- Proximity alerts (distance to attacker)

## Requirements

- Debian-based Linux (tested on Kali)
- WireGuard VPN configured
- XFCE desktop (for panel indicator, optional)
- Packages: `nftables`, `auditd`, `fail2ban`, `kismet`, `xfce4-genmon-plugin`

## How it works on any network

Walk into any WiFi (shelter, library, cafe):
1. Connect — fake MAC, no hostname broadcast
2. Captive portal — works (all private subnets allowed)
3. VPN connects — all traffic encrypted
4. Kill-switch holds — VPN down = no internet
5. ARP watchdog learns new gateway automatically
6. Panel stays green

## License

MIT

---

*Built from the streets. For people who need it most.*

*Ghost with a tripwire.*
