#!/bin/sh
# Phase 2: the mirror (Microsoft 365 -> standby), the outage flag, and fail-back.
. "$(dirname "$0")/lib.sh"
ALICE_PW='dev-Alice-Standby-Protea-58'
RUN=$(date +%H%M%S)
tools() { $DC exec -T tools "$@"; }
tools rm -f /var/lib/zamail/outage /var/lib/zamail/probe.json

echo "1. Mirror brings Sent Items across"
SENT=$(zt append exo alice@corp.test "Sent Items" alice@corp.test customer@example.net "p2-$RUN sent from Outlook")
need "$SENT" "could not place a message in the mock Exchange Online Sent Items"
check "not on the standby before the mirror runs" "$(zt count standby alice@corp.test "Sent Items" "$SENT")" 0
tools python3 /zamail/sync/mirror.py | sed 's/^/     /'
check "in standby Sent Items after the mirror" "$(zt count standby alice@corp.test "Sent Items" "$SENT")" 1

echo "2. No duplicates"
IN=$(zt send sender@example.net alice@corp.test "p2-$RUN inbound")
zt wait exo alice@corp.test INBOX "$IN" 1 >/dev/null; zt wait standby alice@corp.test INBOX "$IN" 1 >/dev/null
tools python3 /zamail/sync/mirror.py >/dev/null
tools python3 /zamail/sync/mirror.py >/dev/null
check "edge-delivered inbox message still appears once" "$(zt count standby alice@corp.test INBOX "$IN")" 1
check "mirrored sent message still appears once" "$(zt count standby alice@corp.test "Sent Items" "$SENT")" 1

echo "3. Probe raises the outage flag, mirror stands down"
$DC stop mock-exo >/dev/null 2>&1
for n in 1 2 3; do tools python3 /zamail/probe/probe.py | sed 's/^/     /'; done
check "outage flag raised after 3 failed probes" "$(tools sh -c 'test -e /var/lib/zamail/outage && echo set || echo clear')" set
check "mirror refuses to run during the outage" "$(tools python3 /zamail/sync/mirror.py | grep -c 'not syncing')" 1

echo "4. Mail sent from ZA Mail during the outage"
OUT=$(zt submit alice@corp.test "$ALICE_PW" bob@corp.test "p2-$RUN internal during outage")
zt wait standby bob@corp.test INBOX "$OUT" 1 >/dev/null
# A mail app or webmail saves the sent copy; the test does the same by hand.
OUTSENT=$(zt append standby alice@corp.test "Sent Items" alice@corp.test customer@example.net "p2-$RUN sent during outage")

echo "5. Recovery and fail-back"
$DC start mock-exo >/dev/null 2>&1
wait_exo_up || bad "mock Exchange Online did not come back"
$DC exec -T edge postqueue -f
for n in 1 2 3 4 5; do tools python3 /zamail/probe/probe.py >/dev/null; done
check "flag is still set after recovery (a person clears it)" "$(tools sh -c 'test -e /var/lib/zamail/outage && echo set || echo clear')" set
tools python3 /zamail/sync/failback.py --days 2 | sed 's/^/     /'
check "outage-time sent mail now in Microsoft 365 Sent Items" "$(zt count exo alice@corp.test "Sent Items" "$OUTSENT")" 1
check "outage-time internal mail now in bob's Microsoft 365 inbox" "$(zt count exo bob@corp.test INBOX "$OUT")" 1
tools python3 /zamail/sync/failback.py --days 2 >/dev/null
check "running fail-back twice adds nothing" "$(zt count exo alice@corp.test "Sent Items" "$OUTSENT")" 1
check "earlier inbound mail was not duplicated in Microsoft 365" "$(zt count exo alice@corp.test INBOX "$IN")" 1
tools rm -f /var/lib/zamail/outage
check "mirror runs again once the flag is cleared" "$(tools python3 /zamail/sync/mirror.py | grep -c ' ok ')" 2

summary
