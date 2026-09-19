#!/usr/bin/env python3
"""Shadow_Shield — panel tray dropdown for toggling privacy/security features.

Sits in the XFCE panel notification area (Gtk.StatusIcon). Click it (either
button) to get a dropdown of checkable toggles for the Shadow_Shield features
that are safe to flip live. Privileged actions run via a spawned terminal
that prompts for `sudo` itself — this script never touches your password.

The menu is rebuilt from live system state every time it's opened, so it
always reflects reality even if you (or install.sh, or the terminal it just
spawned) changed something since the last time you looked.

Run directly:
    python3 gui/shadow-shield-tray.py

Autostart: copy gui/shadow-shield-tray.desktop to ~/.config/autostart/
(not done automatically — see that file's header).

Deliberately NOT included here (see plan): the kill-switch firewall (install.sh
already has a careful auto-revert safety dance for it — a raw toggle would
skip that) and kernel hardening / audit rules (installed unconditionally,
reversing kernel module blacklists wants a reboot to take effect cleanly).
"""

import os
import shutil
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
MONITORING_DIR = os.path.join(REPO_DIR, "monitoring")
PRIVACY_DIR = os.path.join(REPO_DIR, "privacy")

NM_PRIVACY_CONF = "/etc/NetworkManager/conf.d/00-privacy.conf"
BT_PAIRABLE_SCRIPT = "/usr/local/bin/bt-pairable-off-boot.sh"
BT_PAIRABLE_SERVICE = "/etc/systemd/system/bt-pairable-off-boot.service"
BT_MAC_SCRIPT = "/usr/local/bin/bt-mac-spoof-boot.sh"
BT_MAC_SERVICE = "/etc/systemd/system/bt-mac-spoof-boot.service"


def find_terminal():
    for name in ("xfce4-terminal", "x-terminal-emulator", "xterm"):
        path = shutil.which(name)
        if path:
            return path, (name == "xfce4-terminal")
    return None, False


REBOOT_PROMPT = (
    "\nrc=$?\n"
    "if [ $rc -eq 0 ]; then\n"
    "  read -rsn1 -p 'This change needs a reboot to fully apply/verify. "
    "[ENTER] Reboot   [ESC] Cancel: ' key\n"
    "  echo\n"
    "  if [ -z \"$key\" ]; then\n"
    "    echo 'Rebooting...'\n"
    "    sudo reboot\n"
    "  else\n"
    "    echo 'Reboot skipped — change is applied but not yet verified across a boot.'\n"
    "  fi\n"
    "else\n"
    "  echo \"Command failed (exit $rc) — not offering reboot.\"\n"
    "fi\n"
)


def run_in_terminal(shell_cmd, label="", offer_reboot=False):
    """Spawn shell_cmd in a visible terminal so the user sees sudo prompts
    and output. Does not block or wait for it to finish. If offer_reboot is
    set, and the command succeeds, prompts ENTER=reboot / ESC=cancel before
    the terminal closes."""
    term, is_xfce = find_terminal()
    if not term:
        print("No terminal emulator found (tried xfce4-terminal, "
              "x-terminal-emulator, xterm).", file=sys.stderr)
        return
    reboot_part = REBOOT_PROMPT if offer_reboot else ""
    wrapped = f"{shell_cmd}{reboot_part}\necho; read -p 'Press Enter to close ({label})...'"
    flag = "-x" if is_xfce else "-e"
    subprocess.Popen([term, flag, "bash", "-c", wrapped])


# ---------------- state queries (read-only, no sudo needed) ----------------

def systemctl_active(unit, user=False):
    args = ["systemctl"] + (["--user"] if user else []) + ["is-active", "--quiet", unit]
    return subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def unit_file_exists(path):
    return os.path.isfile(path)


# ---------------- the five toggles ----------------
# Each entry: (label, is_on() -> bool, on_cmd, off_cmd, extra_state_note() -> str|None)

def arp_watchdog_state():
    return systemctl_active("arp-watchdog.service")


def bt_mac_rotation_installed():
    return unit_file_exists(BT_MAC_SCRIPT) and unit_file_exists(BT_MAC_SERVICE)


def bt_mac_rotation_state():
    return bt_mac_rotation_installed() and systemctl_active("bt-mac-spoof-boot.service")


def bt_pairable_off_installed():
    return unit_file_exists(BT_PAIRABLE_SCRIPT) and unit_file_exists(BT_PAIRABLE_SERVICE)


def bt_pairable_off_state():
    return bt_pairable_off_installed() and systemctl_active("bt-pairable-off-boot.service")


def ble_link_monitor_state():
    return systemctl_active("ble-link-monitor.service", user=True)


def wifi_privacy_state():
    return unit_file_exists(NM_PRIVACY_CONF)


TOGGLES = [
    {
        "key": "arp",
        "label": "ARP Spoof Watchdog",
        "state": arp_watchdog_state,
        "on": "sudo systemctl enable --now arp-watchdog.service",
        "off": "sudo systemctl disable --now arp-watchdog.service",
    },
    {
        "key": "btmac",
        "label": "Bluetooth MAC Rotation (boot)",
        "state": bt_mac_rotation_state,
        # First-run installs the script + unit, then enables it. Safe to re-run.
        "on": (
            f"sudo cp {MONITORING_DIR}/bt-mac-spoof-boot.sh {BT_MAC_SCRIPT} && "
            f"sudo chmod +x {BT_MAC_SCRIPT} && "
            f"sudo cp {MONITORING_DIR}/bt-mac-spoof-boot.service {BT_MAC_SERVICE} && "
            "sudo systemctl daemon-reload && "
            "sudo systemctl enable --now bt-mac-spoof-boot.service"
        ),
        "off": "sudo systemctl disable --now bt-mac-spoof-boot.service",
        "not_installed_suffix": lambda: "" if bt_mac_rotation_installed() else " (not installed)",
        # --now applies it immediately too, but rotation only really proves
        # itself across a real boot cycle (see the AX211 persistence caveat).
        "on_offer_reboot": True,
    },
    {
        "key": "btpairable",
        "label": "Bluetooth Pairable-Off (boot)",
        "state": bt_pairable_off_state,
        # First-run installs the script + unit (same steps used to bring up
        # bt-mac-spoof-boot.service), then enables it. Safe to re-run.
        "on": (
            f"sudo cp {MONITORING_DIR}/bt-pairable-off-boot.sh {BT_PAIRABLE_SCRIPT} && "
            f"sudo chmod +x {BT_PAIRABLE_SCRIPT} && "
            f"sudo cp {MONITORING_DIR}/bt-pairable-off-boot.service {BT_PAIRABLE_SERVICE} && "
            "sudo systemctl daemon-reload && "
            "sudo systemctl enable --now bt-pairable-off-boot.service"
        ),
        "off": "sudo systemctl disable --now bt-pairable-off-boot.service",
        "not_installed_suffix": lambda: "" if bt_pairable_off_installed() else " (not installed)",
        "on_offer_reboot": True,
    },
    {
        "key": "ble",
        "label": "BLE Link Monitor (user, no sudo)",
        "state": ble_link_monitor_state,
        "on": "systemctl --user enable --now ble-link-monitor.service",
        "off": "systemctl --user disable --now ble-link-monitor.service",
    },
    {
        "key": "wifipriv",
        "label": "WiFi/BT MAC Privacy Config",
        "state": wifi_privacy_state,
        "on": (
            f"sudo cp {PRIVACY_DIR}/00-privacy.conf {NM_PRIVACY_CONF} && "
            "sudo systemctl disable --now avahi-daemon.socket avahi-daemon.service ; "
            "sudo systemctl restart NetworkManager"
        ),
        "off": f"sudo rm -f {NM_PRIVACY_CONF} && sudo systemctl restart NetworkManager",
    },
]


class ShadowShieldTray:
    def __init__(self):
        self.icon = Gtk.StatusIcon()
        self.icon.set_from_icon_name("security-high-symbolic")
        self.icon.set_tooltip_text("Shadow_Shield")
        self.icon.connect("popup-menu", self.on_popup)
        self.icon.connect("activate", self.on_popup)

    def on_popup(self, icon, *args):
        menu = self.build_menu()
        menu.popup_at_pointer(None)

    def build_menu(self):
        menu = Gtk.Menu()

        header = Gtk.MenuItem(label="Shadow_Shield")
        header.set_sensitive(False)
        menu.append(header)
        menu.append(Gtk.SeparatorMenuItem())

        for entry in TOGGLES:
            is_on = entry["state"]()
            suffix = ""
            if "not_installed_suffix" in entry:
                suffix = entry["not_installed_suffix"]()
            item = Gtk.CheckMenuItem(label=entry["label"] + suffix)
            item.set_active(is_on)
            item.connect("toggled", self.on_toggle, entry)
            menu.append(item)

        menu.append(Gtk.SeparatorMenuItem())

        dash = Gtk.MenuItem(label="Open Security Dashboard")
        dash.connect("activate", self.on_dashboard)
        menu.append(dash)

        refresh = Gtk.MenuItem(label="Refresh")
        refresh.connect("activate", self.on_refresh)
        menu.append(refresh)

        menu.append(Gtk.SeparatorMenuItem())

        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", lambda *_: Gtk.main_quit())
        menu.append(quit_item)

        menu.show_all()
        return menu

    def on_toggle(self, item, entry):
        want_on = item.get_active()
        cmd = entry["on"] if want_on else entry["off"]
        offer_reboot = want_on and entry.get("on_offer_reboot", False)
        run_in_terminal(cmd, label=entry["label"], offer_reboot=offer_reboot)

    def on_dashboard(self, *_):
        # The repo copy has __WG_IFACE__/__HOME_DIR__ placeholders only
        # install.sh's render() step fills in — always prefer the installed,
        # rendered copy. If install.sh was never run, say so instead of
        # executing the templated script raw.
        installed = "/usr/local/bin/security-check.sh"
        if os.path.isfile(installed):
            run_in_terminal(f"sudo {installed}", label="Security Dashboard")
        else:
            run_in_terminal(
                "echo 'security-check.sh is not installed yet — run install.sh first.'",
                label="Security Dashboard",
            )

    def on_refresh(self, *_):
        # Menu rebuilds from live state on every open already; re-popup now
        # so "Refresh" visibly does something without waiting for a re-click.
        self.on_popup(self.icon)


def main():
    ShadowShieldTray()
    Gtk.main()


if __name__ == "__main__":
    main()
