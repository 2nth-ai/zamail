#!/bin/sh
# Example PROBE_NOTIFY_CMD. Replace the body with a call to your SMS or WhatsApp gateway.
# It receives one argument: "outage" or "recovering".
#
# The message must reach people who cannot read email or Teams right now, so use a
# channel that does not depend on Microsoft.
case "$1" in
  outage)     MSG="Microsoft 365 mail is down. Use ZA Mail now: ${WEBMAIL_URL:-https://mail.example.co.za}. Your mail is already there." ;;
  recovering) MSG="Microsoft 365 mail looks healthy again. Keep using ZA Mail until IT confirms the switch back." ;;
  *) exit 0 ;;
esac
echo "$(date -u +%FT%TZ) NOTIFY: $MSG" >> "${ZAMAIL_STATE_DIR:-/var/lib/zamail}/notifications.log"
# Example (commented out): a generic HTTPS SMS gateway
# curl -fsS -X POST "$SMS_GATEWAY_URL" -H "Authorization: Bearer $SMS_GATEWAY_TOKEN" \
#      --data-urlencode "to=$SMS_GROUP" --data-urlencode "text=$MSG"
