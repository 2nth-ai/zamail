#!/bin/sh
# One-time setup of a production standby after "docker compose up -d". Safe to re-run:
# it re-applies the configuration plan and runs the provisioner.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/compose/standby"
set -a; . "$ROOT/.env"; set +a
DC="docker compose --env-file $ROOT/.env"

rc=0
$DC exec -T tools sh /zamail/bin/stalwart-setup.sh bootstrap http://standby:8080 \
    "$STANDBY_RECOVERY_PASSWORD" "$STANDBY_HOSTNAME" "$ZAMAIL_PRIMARY_DOMAIN" "${STANDBY_ACME:-true}" || rc=$?
if [ "$rc" = 10 ]; then $DC restart standby; elif [ "$rc" != 0 ]; then exit "$rc"; fi

$DC exec -T tools sh /zamail/bin/stalwart-setup.sh apply http://standby:8080 \
    "$STANDBY_RECOVERY_PASSWORD" /zamail/stalwart/plan/standby.ndjson.tmpl

for d in $ZAMAIL_DOMAINS; do
  [ "$d" = "$ZAMAIL_PRIMARY_DOMAIN" ] && continue
  $DC exec -T -e ZAMAIL_EXTRA_DOMAIN="$d" tools sh /zamail/bin/stalwart-setup.sh apply \
      http://standby:8080 "$STANDBY_RECOVERY_PASSWORD" /zamail/stalwart/plan/domain.ndjson.tmpl
done

$DC exec -T tools python3 /zamail/sync/provision.py
echo "standby-init: done. DKIM and other DNS records: see docs/runbooks/onboarding.md"
