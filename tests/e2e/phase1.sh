#!/bin/sh
# Phase 1: dual delivery, behaviour while "Exchange Online" is down, and recovery.
. "$(dirname "$0")/lib.sh"
ALICE_PW='dev-Alice-Standby-Protea-58'
RUN=$(date +%H%M%S)

echo "1. Normal day: one inbound message reaches both systems"
ID=$(zt send sender@example.net alice@corp.test "p1-$RUN normal day" || true)
need "$ID" "the edge did not accept a message for alice@corp.test"
check "copy in Exchange Online inbox" "$(zt wait exo alice@corp.test INBOX "$ID" 1)" 1
check "copy in ZA Mail standby inbox" "$(zt wait standby alice@corp.test INBOX "$ID" 1)" 1

echo "2. Alias and distribution list"
ID=$(zt send sender@example.net a.mokoena@corp.test "p1-$RUN alias")
check "alias reaches standby mailbox" "$(zt wait standby alice@corp.test INBOX "$ID" 1)" 1
ID=$(zt send sender@example.net team@corp.test "p1-$RUN list")
check "list reaches alice on standby" "$(zt wait standby alice@corp.test INBOX "$ID" 1)" 1
check "list reaches bob on standby"   "$(zt wait standby bob@corp.test INBOX "$ID" 1)" 1
check "list reaches bob on Exchange Online" "$(zt wait exo bob@corp.test INBOX "$ID" 1)" 1

echo "3. Edge refuses what it should"
check "unknown recipient rejected at RCPT" "$(zt rcpt sender@example.net nobody@corp.test | cut -c1-3)" 550
R=$(zt rcpt sender@example.net victim@elsewhere.example | cut -c1-1)
check "edge is not an open relay" "$R" 5

echo "4. Exchange Online goes down"
$DC stop mock-exo >/dev/null 2>&1
ID=$(zt send sender@example.net alice@corp.test "p1-$RUN during outage")
check "new mail still reaches the standby" "$(zt wait standby alice@corp.test INBOX "$ID" 1)" 1
i=0; Q=0; while [ $i -lt 45 ]; do Q=$(exo_queue); [ "$Q" -ge 1 ] && break; i=$((i+1)); sleep 2; done
check "message is held in the edge queue for Exchange Online" "$Q" 1

echo "5. Working from ZA Mail during the outage"
ID2=$(zt submit alice@corp.test "$ALICE_PW" bob@corp.test,customer@example.net "p1-$RUN sent in outage")
check "internal mail delivered on the standby" "$(zt wait standby bob@corp.test INBOX "$ID2" 1)" 1
i=0; S='[]'; while [ $i -lt 20 ]; do S=$(zt sink "p1-$RUN sent in outage"); [ "$S" != "[]" ] && break; i=$((i+1)); sleep 2; done
case "$S" in *'"customer@example.net"'*) ok "external mail left through the edge";; *) bad "external mail left through the edge ($S)";; esac
case "$S" in *'"dkim": true'*) ok "external mail is DKIM-signed";; *) bad "external mail is DKIM-signed";; esac

echo "6. Exchange Online recovers"
$DC start mock-exo >/dev/null 2>&1
wait_exo_up || bad "mock Exchange Online did not come back"
$DC exec -T edge postqueue -f
check "queued message delivered exactly once" "$(zt wait exo alice@corp.test INBOX "$ID" 1 90)" 1
i=0; while [ $i -lt 20 ]; do Q=$(exo_queue); [ "$Q" = 0 ] && break; i=$((i+1)); sleep 2; done
check "edge queue is empty" "$Q" 0
check "standby still holds exactly one copy" "$(zt count standby alice@corp.test INBOX "$ID")" 1

summary
