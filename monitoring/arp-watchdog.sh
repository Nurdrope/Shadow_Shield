#!/bin/bash
# Shadow_Shield — ARP Gateway Watchdog v4
# Honest by design:
#   - A gateway MAC *flapping* between two values is the real ARP-spoof
#     signature (attacker and router fighting for the ARP cache).
#   - A single persistent change is usually a legitimate event (router
#     replaced, mesh node roam, hotspot switch) — logged as WARN, then
#     re-learned. v3 escalated this to "ACTIVE MITM" forever. It isn't.
#   - Counts EVENTS (transitions), not polls.

LOGFILE="/var/log/arp-watchdog.log"
POLL=5             # seconds between checks
FLAP_WINDOW=120    # seconds; flap events inside this window count together
FLAP_TRIP=3        # A->B->A style changes within window => spoof alert
RELEARN_POLLS=6    # persistent new MAC for this many polls => re-learn (30s)

GATEWAY_IP=""; GATEWAY_IF=""; KNOWN_MAC=""
CANDIDATE_MAC=""; CANDIDATE_COUNT=0
FLAP_TIMES=()
ALERTED=0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE" 2>/dev/null; }

log "[INFO] Watchdog v4 started (event-based, flap detection)"

while true; do
    # Current default route + interface
    ROUTE_INFO=$(ip route | awk '/^default via/{print $3, $5; exit}')
    NEW_GW=${ROUTE_INFO%% *}
    NEW_IF=${ROUTE_INFO##* }

    # Network changed => reset baseline (normal, not an alert)
    if [ "$NEW_GW" != "$GATEWAY_IP" ] || [ "$NEW_IF" != "$GATEWAY_IF" ]; then
        GATEWAY_IP="$NEW_GW"; GATEWAY_IF="$NEW_IF"
        KNOWN_MAC=""; CANDIDATE_MAC=""; CANDIDATE_COUNT=0; FLAP_TIMES=(); ALERTED=0
        [ -n "$GATEWAY_IP" ] && log "[INFO] Monitoring gateway $GATEWAY_IP on $GATEWAY_IF"
    fi
    [ -z "$GATEWAY_IP" ] && { sleep "$POLL"; continue; }

    # ip neigh (modern) instead of deprecated arp; only trust fresh entries
    CURRENT_MAC=$(ip neigh show "$GATEWAY_IP" dev "$GATEWAY_IF" 2>/dev/null \
                  | awk '/lladdr/{print $3; exit}')
    [ -z "$CURRENT_MAC" ] && { sleep "$POLL"; continue; }

    if [ -z "$KNOWN_MAC" ]; then
        KNOWN_MAC="$CURRENT_MAC"
        log "[INFO] Learned MAC for $GATEWAY_IP ($GATEWAY_IF): $KNOWN_MAC"

    elif [ "$CURRENT_MAC" != "$KNOWN_MAC" ]; then
        # --- Change EVENT (transition only, not every poll) ---
        if [ "$CURRENT_MAC" != "$CANDIDATE_MAC" ]; then
            CANDIDATE_MAC="$CURRENT_MAC"; CANDIDATE_COUNT=1
            now=$(date +%s); FLAP_TIMES+=("$now")
            log "[WARN] Gateway MAC changed: $KNOWN_MAC -> $CURRENT_MAC on $GATEWAY_IF"

            # prune flap events outside window
            pruned=()
            for t in "${FLAP_TIMES[@]}"; do
                [ $((now - t)) -le "$FLAP_WINDOW" ] && pruned+=("$t")
            done
            FLAP_TIMES=("${pruned[@]}")

            if [ "${#FLAP_TIMES[@]}" -ge "$FLAP_TRIP" ] && [ "$ALERTED" -eq 0 ]; then
                ALERTED=1
                log "[ALERT] MAC flapping: ${#FLAP_TIMES[@]} changes in ${FLAP_WINDOW}s — consistent with ARP spoofing on $GATEWAY_IF"
                logger -p auth.crit "Shadow_Shield: gateway MAC flapping on $GATEWAY_IF (${#FLAP_TIMES[@]} changes/${FLAP_WINDOW}s) — possible ARP spoof"
            fi
        else
            # Same new MAC persisting => probably legitimate; re-learn after threshold
            CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
            if [ "$CANDIDATE_COUNT" -ge "$RELEARN_POLLS" ]; then
                log "[INFO] New MAC stable for $((RELEARN_POLLS * POLL))s — re-learned baseline: $CANDIDATE_MAC (was $KNOWN_MAC). If you did not change routers, investigate."
                KNOWN_MAC="$CANDIDATE_MAC"; CANDIDATE_MAC=""; CANDIDATE_COUNT=0; ALERTED=0
            fi
        fi
    else
        # Back to known MAC. If we saw a candidate in between, that WAS a flap cycle.
        CANDIDATE_MAC=""; CANDIDATE_COUNT=0
    fi

    sleep "$POLL"
done
