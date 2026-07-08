# Shadow_Shield — BLE Link Health Monitor

Honest Bluetooth link monitor with a trusted-device allow-list and rogue-device
**enforcement**. Reports real link quality (0–255) — it does **not** cry "jamming"
from a single reading (that was the v1 false-positive bug; see repo history). Any
connected device that is **not** on your allow-list is a rogue: alerted, and
(when enforcement is on) disconnected and blocked.

## Files
| File | Purpose |
|------|---------|
| `ble-provision.sh`         | Seeds the allow-list from your ALREADY-paired devices (run at install) |
| `ble-link-monitor.sh`      | The monitor loop (link quality + rogue detection/enforcement) |
| `ble-panel.sh`             | XFCE genmon panel widget (green/yellow/gray + red "BLE ROGUE") |
| `ble-link-monitor.service` | systemd **--user** unit |

## Runs as a user service (not system)
Unlike `arp-watchdog` (system, `/usr/local/bin`, `multi-user.target`), this runs
in your **desktop session** — it needs the session D-Bus/display for the
`notify-send` popups and per-user `hcitool`/`bluetoothctl` access.

## Install
```bash
# 1. Copy scripts into your user bin
install -m755 ble-provision.sh ble-link-monitor.sh ble-panel.sh ~/.local/bin/

# 2. Seed the allow-list from devices you have ALREADY paired (trust-on-first-use).
#    This is the safe way to determine your trusted set — no hand-typing MACs.
ble-provision.sh
#    -> writes ~/.config/ble-monitor/trusted.conf ; review it.

# 3. Install + enable the user service (ships in ALERT-ONLY mode)
install -m644 ble-link-monitor.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ble-link-monitor.service

# 4. (Optional) opt into enforcement AFTER reviewing your allow-list:
#    set AUTO_KICK=1 in ble-link-monitor.sh, then restart the service.

# 5. (Optional) add ble-panel.sh as an XFCE "Generic Monitor" (genmon) panel item.
```

## Determining trusted devices (why provisioning matters)
A device you have **paired** already passed BlueZ's pairing authorization — you
personally approved it. `ble-provision.sh` reads `bluetoothctl devices Paired`
and treats those as your trust baseline. Anything that connects *afterward* and
isn't on the list is the rogue. This is why you should provision at install
rather than start from an empty list — otherwise deny-by-default would kick your
own gear (including a Bluetooth **keyboard/mouse**).

## Enforcement & the anti-lockout guard
`AUTO_KICK=0` (default) → alert only. `AUTO_KICK=1` → rogue devices are
disconnected + **blocked** (BlueZ refuses them; re-admit with
`bluetoothctl unblock <MAC>`).

Blocking is uniform for audio devices. For **input devices (keyboard/mouse)** the
monitor checks whether a non-Bluetooth keyboard exists (built-in/USB, via
`/proc/bus/input/devices`):
- **Fallback present** → treated like anything else: disconnected + blocked.
- **No fallback** → disconnected (stops keystroke injection) but **not blocked**,
  so you can never block your only way to type. Alerted for manual review.

Why input devices get this care: a rogue **keyboard** is the worst case — it can
inject keystrokes into your session. The detection is identical to any other
rogue; only the *cost of a false block* differs (lose audio vs. lose your only
keyboard), so blocking is gated on having a fallback.

## Behavior
| Situation | Panel | Enforcement (AUTO_KICK=1) |
|-----------|-------|---------------------------|
| Trusted device connected | 🔵 green / yellow / orange by link quality | — |
| Nothing connected | ○ gray "BLE off" | — |
| **Rogue audio device** | 🔴 red "BLE ROGUE" | disconnect + block |
| **Rogue input + fallback keyboard** | 🔴 red "BLE ROGUE" | disconnect + block |
| **Rogue input, NO fallback** | 🔴 red "BLE ROGUE" | disconnect + alert (no block) |

Rogue alerts fire **once per connection** (not every poll) and clear on disconnect.

## Hardening tip (preventive)
Enforcement is reactive. To stop new pairings entirely, keep the adapter
non-pairable except when you're deliberately adding a device:
```bash
bluetoothctl pairable off      # nothing new can bond
bluetoothctl pairable on       # ...only when YOU want to pair, then off again
```

## Adding new gear
Pair it, then re-baseline and restart:
```bash
ble-provision.sh
systemctl --user restart ble-link-monitor.service
```
(Or add its MAC to `~/.config/ble-monitor/trusted.conf` by hand.) Anything you
don't add trips a rogue alert — that's intentional.

## Logs
- `~/.local/share/ble-monitor/link-monitor.log` — link state events
- `~/.local/share/ble-monitor/security-events.log` — rogue-device alerts/enforcement
- `~/.local/share/ble-monitor/lq-timeline.csv` — full link-quality timeline
