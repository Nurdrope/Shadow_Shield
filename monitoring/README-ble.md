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
| `ble-link-monitor.service` | systemd **--user** unit for the monitor |
| `bt-pairable-off.sh`       | Sets the adapter non-pairable at session start (preventive) |
| `bt-pairable-off.service`  | systemd **--user** oneshot for the above |
| `bt-pairable-off-boot.sh`      | Same, but at BOOT — **system** (root) variant |
| `bt-pairable-off-boot.service` | systemd **system** oneshot for the boot variant |

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
| Bonded device, not on allow-list (`TRUST_BONDED=1`) | unchanged | — (trusted by bond) |
| Unbonded device while **pairing mode is open** | unchanged | held, not kicked (pairing can finish) |
| Nothing connected | ○ gray "BLE off" | — |
| **Rogue audio device** | 🔴 red "BLE ROGUE" | disconnect + block |
| **Rogue input + fallback keyboard** | 🔴 red "BLE ROGUE" | disconnect + block |
| **Rogue input, NO fallback** | 🔴 red "BLE ROGUE" | disconnect + alert (no block) |

Rogue alerts fire **once per connection** (not every poll) and clear on disconnect.

## Bond-trust (`TRUST_BONDED=1`, default)
Some gear changes its Bluetooth address every time it is re-paired — Logitech
K850/M720 bump the last byte (`…:84` → `…:85` → `…:86`). With a MAC-only
allow-list, every re-pair (e.g. after a reboot with BT MAC rotation) gets your own
keyboard kicked and blocked.

Bond-trust fixes that: a connected device that holds a BlueZ **pairing bond**
(`Bonded: yes`) is trusted even if its MAC isn't on the allow-list. This is
*stronger* evidence than a MAC match — a MAC is trivially spoofed, but a spoofed
MAC can't reuse the bond's keys — and a bond can only be created while **you**
have pairing mode open (which `bt-pairable-off` keeps closed by default).

Pairing-window caveat: a new device connects *before* its bond completes, so while
the adapter is pairable, unbonded devices are **held** (logged, not kicked) so
pairing can finish. Once pairing closes, anything still unbonded is a rogue as
usual. Keep the pairing window short. Set `TRUST_BONDED=0` for a strict MAC-only
allow-list.

## Preventive hardening: non-pairable by default
The monitor's enforcement is *reactive* (it responds after a device connects).
`bt-pairable-off.sh` adds the *preventive* layer: it sets the adapter
**non-pairable** at session start, so no NEW device can bond unless you
deliberately re-enable pairing. Combined with enforcement that's defense in
depth — prevent, detect, respond.

```bash
install -m755 bt-pairable-off.sh ~/.local/bin/
install -m644 bt-pairable-off.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now bt-pairable-off.service
```

It has a retry loop that waits for the controller to power up, and logs the
result to `security-events.log`. Existing bonded devices still reconnect
normally — `pairable off` only blocks *new* bonds.

**Honest scope — pre-login window:** the user service applies at login, not at
kernel boot. There's a brief window at boot (before you log in) where the adapter
could still be pairable. For a single-user laptop that's negligible (Discoverable
is off and no one's at the machine pre-login).

### True-boot (system) variant
To close that window, install the **system** variant instead — it runs as root
right after `bluetooth.service`, before any login. Needs root:
```bash
sudo install -m755 bt-pairable-off-boot.sh /usr/local/bin/
sudo install -m644 bt-pairable-off-boot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bt-pairable-off-boot.service
# then retire the redundant per-user oneshot:
systemctl --user disable --now bt-pairable-off.service
```
It logs to journald + syslog (`journalctl -u bt-pairable-off-boot` or
`grep shadow-shield /var/log/syslog`). **Use EITHER the user oneshot OR the
system service, not both** — the system one supersedes the user one.

## Adding new gear
With non-pairable hardening on, pairing is a deliberate act:
```bash
bluetoothctl pairable on                          # open the window
# ...pair + trust + connect the device via bluetoothctl / your DE...
bluetoothctl pairable off                         # re-lock
```
With bond-trust on (default) that's it — the bond is the trust. With
`TRUST_BONDED=0`, also add its MAC to `~/.config/ble-monitor/trusted.conf` and
restart `ble-link-monitor.service`. (Don't re-run `ble-provision.sh` for this: it
rebuilds the list from *currently* paired devices and drops anything not paired
right now.) Any unbonded device that connects outside the pairing window trips a
rogue alert — that's intentional.

## Logs
- `~/.local/share/ble-monitor/link-monitor.log` — link state events
- `~/.local/share/ble-monitor/security-events.log` — rogue-device alerts/enforcement
- `~/.local/share/ble-monitor/lq-timeline.csv` — full link-quality timeline
