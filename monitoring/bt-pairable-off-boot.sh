#!/bin/bash
# Shadow_Shield — set the Bluetooth adapter NON-pairable at BOOT (system service).
#
# True-boot variant of bt-pairable-off.sh. Runs as ROOT after bluetooth.service,
# closing the brief pre-login window that the per-user oneshot leaves open. Use
# EITHER this OR the user service, not both (see README).
#
# Install to /usr/local/bin; pair with bt-pairable-off-boot.service.
# Logs to journald (stdout) + syslog (tag: shadow-shield). Does NOT use $HOME.

# Wait (up to ~30s) for a powered controller — the adapter may still be coming up.
for _ in $(seq 1 30); do
    state=$(timeout 5 bluetoothctl show 2>/dev/null)
    if grep -q 'Controller' <<<"$state" && grep -q 'Powered: yes' <<<"$state"; then
        break
    fi
    sleep 1
done

timeout 5 bluetoothctl pairable off      >/dev/null 2>&1
timeout 5 bluetoothctl discoverable off  >/dev/null 2>&1

show=$(timeout 5 bluetoothctl show 2>/dev/null)
pair=$(grep -oP 'Pairable:\s*\K\w+'     <<<"$show")
disc=$(grep -oP 'Discoverable:\s*\K\w+' <<<"$show")
msg="HARDEN(boot) pairable=${pair:-?} discoverable=${disc:-?}"
echo "$msg"
logger -t shadow-shield "$msg" 2>/dev/null
