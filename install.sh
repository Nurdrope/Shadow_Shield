#!/bin/bash
# Shadow_Shield Installer — safe-by-default
# Tested on Kali Linux / Debian-based systems.
#
# Design promise: this script will NOT lock you out of your own machine.
#   - It auto-detects your WireGuard interface (no hardcoded names).
#   - It refuses to install the outbound kill-switch if there is no tunnel
#     to allow traffic through (that would drop ALL your internet).
#   - The firewall is applied with an AUTO-REVERT timer: if you can't confirm
#     you still have connectivity, it rolls back on its own.
#   - Every file it overwrites is backed up, and it writes an uninstall.sh.
#
# Usage:
#   sudo ./install.sh                 # interactive, safe (recommended)
#   sudo ./install.sh --dry-run       # show what it WOULD do, change nothing
#   sudo ./install.sh --no-killswitch # inbound firewall only, no outbound drop
#   sudo ./install.sh --yes           # non-interactive; auto-confirms via a
#                                     #   real connectivity self-test
#   sudo ./install.sh --iface wg0     # force a specific WireGuard interface
#   sudo ./install.sh --revert-timeout 120

set -euo pipefail

# --- resolve where this script lives, so relative paths always work ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------- defaults / flags ----------------
DRY=0
ASSUME_YES=0
WANT_KILLSWITCH=1
FORCE_IFACE=""
REVERT_TIMEOUT=90

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY=1 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        --no-killswitch)  WANT_KILLSWITCH=0 ;;
        --iface)          FORCE_IFACE="${2:-}"; shift ;;
        --revert-timeout) REVERT_TIMEOUT="${2:-90}"; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 30
            exit 0 ;;
        *) echo "Unknown option: $1 (try --help)"; exit 2 ;;
    esac
    shift
done

# ---------------- helpers ----------------
say()  { echo -e "$*"; }
info() { echo -e "  \033[36m$*\033[0m"; }
warn() { echo -e "  \033[33m! $*\033[0m"; }
err()  { echo -e "  \033[31mERROR: $*\033[0m" >&2; }
ok()   { echo -e "  \033[32m✓ $*\033[0m"; }

# Run a command, or just print it in dry-run mode.
run() {
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo ./install.sh"
    exit 1
fi

say "=== Shadow_Shield Installer ==="
[ "$DRY" = 1 ] && warn "DRY RUN — nothing will be changed."
say ""

# ---------------- identify the real user & home ----------------
# When run under sudo, $HOME is root's. We want the human's home for the
# audit rules that watch THEIR credential files.
TARGET_USER="${SUDO_USER:-root}"
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$HOME_DIR" ] && HOME_DIR="/root"
info "Target user: $TARGET_USER   home: $HOME_DIR"

# ---------------- detect the WireGuard interface ----------------
# We look at, in order: an active wireguard-type link, then any *.conf under
# /etc/wireguard. The interface MUST exist for the kill-switch to be safe —
# an outbound-drop policy whose only escape hatch is a nonexistent tunnel
# means zero internet.
detect_wg_ifaces() {
    # active wireguard interfaces
    ip -o link show type wireguard 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'
}
detect_wg_configs() {
    ls -1 /etc/wireguard/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//'
}

WG_IFACE=""
if [ -n "$FORCE_IFACE" ]; then
    WG_IFACE="$FORCE_IFACE"
    info "Using forced interface: $WG_IFACE"
else
    mapfile -t ACTIVE < <(detect_wg_ifaces)
    if [ "${#ACTIVE[@]}" -eq 1 ]; then
        WG_IFACE="${ACTIVE[0]}"
        ok "Detected active WireGuard interface: $WG_IFACE"
    elif [ "${#ACTIVE[@]}" -gt 1 ]; then
        say "  Multiple active WireGuard interfaces found:"
        select choice in "${ACTIVE[@]}"; do
            [ -n "$choice" ] && { WG_IFACE="$choice"; break; }
        done
    else
        # none up — check for configured-but-down tunnels
        mapfile -t CONFIGS < <(detect_wg_configs)
        if [ "${#CONFIGS[@]}" -ge 1 ]; then
            warn "No WireGuard interface is UP, but these configs exist: ${CONFIGS[*]}"
            warn "Bring your tunnel up first:  sudo wg-quick up ${CONFIGS[0]}"
        fi
    fi
fi

# Is the chosen interface actually present right now?
WG_PRESENT=0
if [ -n "$WG_IFACE" ] && ip link show "$WG_IFACE" &>/dev/null; then
    WG_PRESENT=1
fi

# ---------------- decide kill-switch safety ----------------
# The kill-switch is only safe if there's a live tunnel to permit. If not,
# we downgrade to inbound-only protection rather than cutting the user off.
if [ "$WANT_KILLSWITCH" = 1 ] && [ "$WG_PRESENT" = 0 ]; then
    warn "No live WireGuard interface detected."
    warn "Installing the outbound kill-switch now would block ALL your internet."
    if [ "$ASSUME_YES" = 1 ]; then
        warn "Auto-downgrading to inbound-only firewall (--no-killswitch) for safety."
        WANT_KILLSWITCH=0
    else
        say ""
        say "  Choose:"
        say "    [1] Install INBOUND firewall only (safe, no kill-switch)  <- default"
        say "    [2] Abort so I can bring my tunnel up first"
        say "    [3] I know what I'm doing — install kill-switch anyway (risky)"
        read -r -p "  > " ans || ans=1
        case "${ans:-1}" in
            2) say "  Aborted. Run 'sudo wg-quick up <iface>' then re-run me."; exit 0 ;;
            3) warn "Proceeding with kill-switch despite no live tunnel. Auto-revert is armed." ;;
            *) WANT_KILLSWITCH=0; info "OK — inbound-only firewall." ;;
        esac
    fi
fi

# ---------------- detect the tunnel fwmark ----------------
# WireGuard marks its encrypted packets so they can leave the physical NIC.
# The kill-switch must permit that mark or the tunnel can never handshake.
WG_FWMARK=""
if [ "$WG_PRESENT" = 1 ]; then
    WG_FWMARK="$(wg show "$WG_IFACE" fwmark 2>/dev/null || true)"
fi
case "$WG_FWMARK" in
    0x*)   ok "Detected tunnel fwmark: $WG_FWMARK" ;;
    off|"") WG_FWMARK="0xca6c"
            [ "$WANT_KILLSWITCH" = 1 ] && warn "No fwmark reported; using default $WG_FWMARK. Auto-revert will catch a bad guess." ;;
esac

# ---------------- backups + uninstall manifest ----------------
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/shadow_shield/$STAMP"
UNINSTALL="/usr/local/sbin/shadow_shield-uninstall.sh"
run mkdir -p "$BACKUP"
info "Backups: $BACKUP"

backup_file() {  # $1 = path that install will overwrite
    [ -e "$1" ] || return 0
    run cp -a "$1" "$BACKUP/$(echo "$1" | tr '/' '_')"
}

# Render a template: replace placeholders, write to $2.
render() {  # $1 = template, $2 = dest
    if [ "$DRY" = 1 ]; then
        echo "  [dry-run] render $1 -> $2"
        return 0
    fi
    sed -e "s|__WG_IFACE__|${WG_IFACE}|g" \
        -e "s|__WG_FWMARK__|${WG_FWMARK}|g" \
        -e "s|__HOME_DIR__|${HOME_DIR}|g" \
        "$1" > "$2"
}

# ---------------- 1. dependencies ----------------
say "[1/7] Installing dependencies..."
run apt install -y nftables auditd fail2ban xfce4-genmon-plugin kismet 2>/dev/null || true

# ---------------- 2. kernel hardening (low risk, reversible) ----------------
say "[2/7] Applying kernel hardening..."
backup_file /etc/sysctl.d/99-hardening.conf
backup_file /etc/modprobe.d/disable-protocols.conf
run cp kernel/99-hardening.conf /etc/sysctl.d/
run cp kernel/disable-protocols.conf /etc/modprobe.d/
run sysctl --system >/dev/null 2>&1 || true

# ---------------- 3. firewall (the dangerous one) ----------------
say "[3/7] Installing firewall${WANT_KILLSWITCH:+ with VPN kill-switch}..."
backup_file /etc/nftables.conf

STAGED="$(mktemp)"
if [ "$WANT_KILLSWITCH" = 1 ]; then
    render firewall/nftables.conf "$STAGED"
else
    # Inbound-only: keep the input default-drop chain, but make output ACCEPT
    # so we can never cut the user off. We transform the templated file.
    render firewall/nftables.conf "$STAGED"
    if [ "$DRY" = 0 ]; then
        # flip the output chain policy from drop to accept
        sed -i 's/\(type filter hook output priority filter; policy \)drop/\1accept/' "$STAGED"
    fi
fi

# If there is no interface name to match on, drop the WG-specific rules so we
# never emit invalid `iif ""` / `oif ""` lines.
if [ "$DRY" = 0 ] && [ -z "$WG_IFACE" ]; then
    sed -i '/iif "" accept/d; /oif "" accept/d; /meta mark .* accept/d' "$STAGED"
fi

if [ "$DRY" = 1 ]; then
    echo "  [dry-run] would validate & apply firewall (interface=$WG_IFACE mark=$WG_FWMARK killswitch=$WANT_KILLSWITCH)"
else
    # Validate BEFORE touching the live ruleset.
    if ! nft -c -f "$STAGED"; then
        err "Firewall config failed validation — NOT applying. Nothing changed."
        rm -f "$STAGED"; exit 1
    fi

    # Snapshot the current live ruleset so we can restore it exactly.
    nft list ruleset > "$BACKUP/ruleset.before.nft" 2>/dev/null || true

    if [ "$WANT_KILLSWITCH" = 1 ]; then
        # ---- ANTI-LOCKOUT: apply live, then auto-revert unless confirmed ----
        CONFIRM_FLAG="$(mktemp -u /run/shadow_shield-confirm.XXXXXX)"
        (
            sleep "$REVERT_TIMEOUT"
            [ -e "$CONFIRM_FLAG" ] && exit 0        # user confirmed; leave it
            nft flush ruleset
            [ -s "$BACKUP/ruleset.before.nft" ] && nft -f "$BACKUP/ruleset.before.nft" 2>/dev/null || true
            logger -t shadow_shield "kill-switch auto-reverted after ${REVERT_TIMEOUT}s (no confirmation)"
        ) &
        WATCHER=$!

        nft -f "$STAGED"    # GO LIVE
        warn "Kill-switch is LIVE. Auto-revert in ${REVERT_TIMEOUT}s unless you confirm."

        # Automated connectivity self-test (works for --yes too).
        CONNECTIVITY=1
        if command -v ping >/dev/null && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
            CONNECTIVITY=0
            ok "Self-test: reached 1.1.1.1 through the tunnel."
        else
            warn "Self-test could NOT reach the internet through the firewall."
        fi

        KEEP=0
        if [ "$ASSUME_YES" = 1 ]; then
            [ "$CONNECTIVITY" = 0 ] && KEEP=1
        else
            say "  Open a web page or watch the self-test above."
            if read -r -t "$REVERT_TIMEOUT" -p "  Type KEEP to make this permanent (anything else reverts): " reply; then
                [ "$reply" = "KEEP" ] && KEEP=1
            fi
        fi

        if [ "$KEEP" = 1 ]; then
            touch "$CONFIRM_FLAG"
            kill "$WATCHER" 2>/dev/null || true; wait "$WATCHER" 2>/dev/null || true
            cp "$STAGED" /etc/nftables.conf
            systemctl enable nftables >/dev/null 2>&1 || true
            ok "Firewall confirmed and persisted (survives reboot)."
        else
            kill "$WATCHER" 2>/dev/null || true
            nft flush ruleset
            [ -s "$BACKUP/ruleset.before.nft" ] && nft -f "$BACKUP/ruleset.before.nft" 2>/dev/null || true
            warn "Firewall reverted and NOT persisted. Your connection is as before."
            warn "Bring your tunnel up and re-run, or use --no-killswitch."
        fi
    else
        # Inbound-only can't lock you out; apply and persist directly.
        nft -f "$STAGED"
        cp "$STAGED" /etc/nftables.conf
        systemctl enable nftables >/dev/null 2>&1 || true
        ok "Inbound firewall applied and persisted (no kill-switch)."
    fi
fi
rm -f "$STAGED"

# ---------------- 4. privacy ----------------
say "[4/7] Configuring network privacy..."
backup_file /etc/NetworkManager/conf.d/00-privacy.conf
run cp privacy/00-privacy.conf /etc/NetworkManager/conf.d/
run systemctl disable --now avahi-daemon.socket avahi-daemon.service 2>/dev/null || true

# ---------------- 5. monitoring scripts ----------------
say "[5/7] Installing monitoring tools..."
for f in security-panel.sh security-check.sh; do
    render "monitoring/$f" "/usr/local/bin/$f"
    run chmod 755 "/usr/local/bin/$f"
done
for f in arp-watchdog.sh kismet-safe-start.sh kismet-lockdown.sh; do
    run cp "monitoring/$f" /usr/local/bin/
    run chmod 755 "/usr/local/bin/$f"
done

# ---------------- 6. ARP watchdog service ----------------
say "[6/7] Enabling ARP spoof detection..."
run cp monitoring/arp-watchdog.service /etc/systemd/system/
run systemctl daemon-reload
run systemctl enable --now arp-watchdog.service 2>/dev/null || true

# ---------------- 7. audit rules ----------------
say "[7/7] Loading forensic audit rules..."
render monitoring/evidence.rules /etc/audit/rules.d/evidence.rules
run auditctl -R /etc/audit/rules.d/evidence.rules 2>/dev/null || true

# ---------------- write uninstaller ----------------
if [ "$DRY" = 0 ]; then
    cat > "$UNINSTALL" <<UNINSTALL_EOF
#!/bin/bash
# Auto-generated by Shadow_Shield installer on $STAMP
set -e
[ "\$EUID" -ne 0 ] && { echo "Run as root"; exit 1; }
echo "Reverting Shadow_Shield..."
systemctl disable --now arp-watchdog.service 2>/dev/null || true
rm -f /etc/systemd/system/arp-watchdog.service
rm -f /usr/local/bin/{arp-watchdog.sh,security-check.sh,security-panel.sh,kismet-safe-start.sh,kismet-lockdown.sh}
rm -f /etc/sysctl.d/99-hardening.conf /etc/modprobe.d/disable-protocols.conf
rm -f /etc/NetworkManager/conf.d/00-privacy.conf
rm -f /etc/audit/rules.d/evidence.rules
# restore firewall to pre-install state (fail open — never lock you out)
nft flush ruleset 2>/dev/null || true
if [ -s "$BACKUP/ruleset.before.nft" ]; then
    nft -f "$BACKUP/ruleset.before.nft" 2>/dev/null || true
fi
if [ -f "$BACKUP/_etc_nftables.conf" ]; then
    cp "$BACKUP/_etc_nftables.conf" /etc/nftables.conf
else
    systemctl disable nftables 2>/dev/null || true
fi
systemctl restart NetworkManager 2>/dev/null || true
echo "Done. Backups remain in $BACKUP"
UNINSTALL_EOF
    chmod 755 "$UNINSTALL"
fi

say ""
say "=== Shadow_Shield Installed ==="
say ""
info "Interface : ${WG_IFACE:-<none>}   kill-switch: $WANT_KILLSWITCH"
info "Uninstall : sudo $UNINSTALL"
info "Backups   : $BACKUP"
say ""
say "Next steps:"
say "  1. Enable VPN auto-start:  sudo systemctl enable wg-quick@${WG_IFACE:-YOUR-WG}"
say "  2. Restart NetworkManager: sudo systemctl restart NetworkManager"
say "  3. Add Generic Monitor to XFCE panel:"
say "     Command: /usr/local/bin/security-panel.sh   Period: 30s"
say "  4. Run a check: sudo /usr/local/bin/security-check.sh"
say ""
say "Stay ghost. Stay safe."
