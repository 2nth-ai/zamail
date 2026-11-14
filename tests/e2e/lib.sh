# Shared helpers for the end-to-end tests. Sourced by the phase scripts.
cd "$(dirname "$0")/../../compose/dev"
DC="docker compose"
PASS=0; FAIL=0
zt()   { $DC exec -T tools python3 /zamail/tests/e2e/zt.py "$@"; }
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $3, got $2)"; fi; }
exo_queue() { $DC exec -T edge postqueue -j 2>/dev/null | grep -c '"delay_reason"' || true; }
wait_exo_up() {
  i=0; until $DC exec -T tools sh -c 'nc -z -w 2 mock-exo 25' 2>/dev/null; do
    i=$((i+1)); [ $i -gt 40 ] && return 1; sleep 2; done; sleep 3
}
need() { if [ -z "$1" ]; then echo "  ABORT  $2"; echo; echo "$PASS passed, $((FAIL+1)) failed"; exit 1; fi; }
summary() { echo; echo "$PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; }
