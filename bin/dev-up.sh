#!/bin/sh
# Brings up the local development stack and configures it. Safe to re-run.
set -eu
cd "$(dirname "$0")/../compose/dev"
DC="docker compose"

$DC up -d --build

setup_server() {  # service  url  recovery-password  hostname
  rc=0
  $DC exec -T tools sh /zamail/bin/stalwart-setup.sh bootstrap "$2" "$3" "$4" corp.test false || rc=$?
  if [ "$rc" = 10 ]; then $DC restart "$1" >/dev/null; elif [ "$rc" != 0 ]; then exit "$rc"; fi
}
setup_server standby  http://standby:8080  dev-recovery-Standby-7391 standby.corp.test
setup_server mock-exo http://mock-exo:8080 dev-recovery-MockExo-5528 mock-exo.corp.test

$DC exec -T -e ZAMAIL_PRIMARY_DOMAIN=corp.test tools sh /zamail/bin/stalwart-setup.sh apply \
    http://standby:8080 dev-recovery-Standby-7391 /zamail/stalwart/plan/standby.ndjson.tmpl /zamail/compose/dev/dev-only.ndjson.tmpl
$DC exec -T tools sh /zamail/bin/stalwart-setup.sh apply \
    http://mock-exo:8080 dev-recovery-MockExo-5528 /zamail/compose/dev/mock-exo.ndjson.tmpl /zamail/compose/dev/dev-only.ndjson.tmpl

$DC exec -T tools python3 /zamail/sync/provision.py

# The edge re-reads the recipient list every 30 seconds. Wait until it accepts mail.
i=0
until $DC exec -T tools python3 /zamail/tests/e2e/zt.py rcpt probe@example.net alice@corp.test 2>/dev/null | grep -q '^250'; do
  i=$((i+1)); [ $i -gt 30 ] && { echo "dev-up: the edge is not accepting mail for alice@corp.test" >&2; exit 1; }
  sleep 3
done

cat <<MSG

ZA Mail development stack is up.
  Webmail (standby)        http://localhost:8088   alice@corp.test / dev-Alice-Standby-Protea-58
  Standby admin            http://localhost:8081   admin / dev-recovery-Standby-7391
  Mock Exchange Online     http://localhost:8082   admin / dev-recovery-MockExo-5528
  "Internet" outbound sink http://localhost:8025
  Edge SMTP (the MX)       localhost:2525
Run the tests:  tests/e2e/run.sh
MSG
