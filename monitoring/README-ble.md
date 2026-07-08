# Shadow_Shield — BLE Link Health Monitor

Honest Bluetooth-audio link monitor with a trusted-device allow-list and
rogue-device alerting. Reports real link quality (0–255) — it does **not** cry
"jamming" from a single reading (that was the v1 false-positive bug; see repo
history). Any connected device that is **not** on your allow-list raises a
security alert instead of being treated as a healthy link.

## Files
| File | Purpose |
|------|---------|
| `ble-link-monitor.sh`      | The monitor loop (polls link quality, detects rogue connects) |
| `ble-panel.sh`             | XFCE genmon panel widget (green/yellow/gray + red "BLE ROGUE") |
| `ble-link-monitor.service` | systemd **--user** unit |

## Runs as a user service (not system)
Unlike `arp-watchdog` (system, `/usr/local/bin`, `multi-user.target`), this runs
in your **desktop session** — it needs the session D-Bus/display for the
`notify-send` popups and per-user `hcitool`/`bluetoothctl` access.

## Install
```bash
# 1. Copy scripts into your user bin
install -m755 ble-link-monitor.sh ble-panel.sh ~/.local/bin/

# 2. EDIT THE ALLOW-LIST — this is required.
#    List your paired devices and paste their MACs into the TRUSTED array:
bluetoothctl devices Paired
$EDITOR ~/.local/bin/ble-link-monitor.sh   # replace AA:BB:CC:DD:EE:0x placeholders

# 3. Install + enable the user service
install -m644 ble-link-monitor.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ble-link-monitor.service

# 4. (Optional) add ble-panel.sh as an XFCE "Generic Monitor" (genmon) panel item.
```

## Behavior
| Situation | Panel | Extra |
|-----------|-------|-------|
| Trusted device connected | 🔵 green / 🔵 yellow / 📶 orange by link quality | — |
| Nothing connected | ○ gray "BLE off" | — |
| **Untrusted device connected** | 🔴 red "BLE ROGUE" | logged to `security-events.log` + critical desktop popup |

Rogue alerts fire **once per connection** (not every poll) and clear when the
device disconnects.

## Adding new gear
Add its MAC to the `TRUSTED` array and restart:
```bash
systemctl --user restart ble-link-monitor.service
```
Any device you don't add will trip a rogue alert — that's intentional.

## Logs
- `~/.local/share/ble-monitor/link-monitor.log` — link state events
- `~/.local/share/ble-monitor/security-events.log` — rogue-device alerts
- `~/.local/share/ble-monitor/lq-timeline.csv` — full link-quality timeline
