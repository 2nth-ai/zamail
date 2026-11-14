#!/bin/sh
# Renders the Postfix configuration from environment variables and starts Postfix.
#
# Required:
#   ZAMAIL_DOMAINS     space-separated customer mail domains, e.g. "corp.co.za corp.com"
#   EDGE_HOSTNAME      public name of this MX, e.g. mx1.zamail.corp.co.za
#   EXO_HOST           tenant endpoint, e.g. corp-co-za.mail.protection.outlook.com
#   STANDBY_HOSTS      space-separated standby intake hosts (one per standby node)
# Optional:
#   EXO_PORT (25)  STANDBY_PORT (25)  QUEUE_LIFETIME (10d)
#   TRUSTED_NETS       CIDRs allowed to relay outbound through the edge (the standby nodes)
#   OUTBOUND_RELAY     next hop for mail to the internet, e.g. "[smtp.example]:25"; empty = direct MX
#   EXO_TLS_LEVEL      Postfix TLS level towards EXO (default "encrypt"; dev uses "may")
#   TLS_CERT / TLS_KEY certificate presented to senders and to EXO (the connector matches on it)
#   RECIPIENTS_FILE    valid recipient list, one address per line (default /etc/zamail/recipients)
set -eu

: "${ZAMAIL_DOMAINS:?}" "${EDGE_HOSTNAME:?}" "${EXO_HOST:?}" "${STANDBY_HOSTS:?}"
EXO_PORT="${EXO_PORT:-25}"
STANDBY_PORT="${STANDBY_PORT:-25}"
QUEUE_LIFETIME="${QUEUE_LIFETIME:-10d}"
TRUSTED_NETS="${TRUSTED_NETS:-}"
OUTBOUND_RELAY="${OUTBOUND_RELAY:-}"
EXO_TLS_LEVEL="${EXO_TLS_LEVEL:-encrypt}"
RECIPIENTS_FILE="${RECIPIENTS_FILE:-/etc/zamail/recipients}"
# Shadow suffix: a copy for user@corp.co.za is addressed to user@corp.co.za.<SHADOW>
# inside the edge only, so it can take a different route. It never leaves the edge.
SHADOW="zamail-standby.invalid"

P=/etc/postfix
: > $P/transport
: > $P/recipient_bcc.pcre
: > $P/virtual.pcre
: > $P/standby_generic.pcre
RELAY_DOMAINS=""

# For each customer domain:
#   1. the real address is relayed to Exchange Online (transport "exo");
#   2. recipient_bcc adds a copy addressed to user@<domain>.<SHADOW>;
#   3. virtual_alias fans that copy out to one shadow address per standby node;
#   4. each node has its own transport and queue, and the shadow address is
#      rewritten back to the real address on delivery (smtp_generic_maps).
# A dead standby node therefore never delays Exchange Online or the other node.
for d in $ZAMAIL_DOMAINS; do
  esc=$(printf '%s' "$d" | sed 's/\./\\./g')
  RELAY_DOMAINS="$RELAY_DOMAINS $d"
  echo "$d exo:[$EXO_HOST]:$EXO_PORT" >> $P/transport
  echo "/^(.+)@${esc}\$/ \${1}@${d}.${SHADOW}" >> $P/recipient_bcc.pcre
  echo "/^(.+)@${esc}\\.s[0-9]+\\.zamail-standby\\.invalid\$/ \${1}@${d}" >> $P/standby_generic.pcre
  targets=""
  i=0
  for h in $STANDBY_HOSTS; do
    i=$((i+1))
    echo "$d.s$i.$SHADOW standby$i:[$h]:$STANDBY_PORT" >> $P/transport
    targets="${targets}${targets:+, }\${1}@${d}.s${i}.${SHADOW}"
  done
  echo "/^(.+)@${esc}\\.zamail-standby\\.invalid\$/ ${targets}" >> $P/virtual.pcre
done

# Valid recipients. Unknown addresses are rejected at RCPT so the edge never
# accepts mail it would later have to bounce.
mkdir -p "$(dirname "$RECIPIENTS_FILE")"
[ -f "$RECIPIENTS_FILE" ] || : > "$RECIPIENTS_FILE"
build_recipients() {
  grep -v '^[[:space:]]*\(#\|$\)' "$RECIPIENTS_FILE" | awk '{print tolower($1) " OK"}' > $P/relay_recipients.new || true
  mv $P/relay_recipients.new $P/relay_recipients
}
build_recipients

postconf -e \
  "compatibility_level = 3.6" \
  "myhostname = $EDGE_HOSTNAME" \
  "mydestination =" \
  "mynetworks = 127.0.0.0/8 $TRUSTED_NETS" \
  "inet_interfaces = all" \
  "inet_protocols = ipv4" \
  "maillog_file = /dev/stdout" \
  "relay_domains =$RELAY_DOMAINS" \
  "relay_recipient_maps = texthash:$P/relay_recipients" \
  "unknown_relay_recipient_reject_code = 550" \
  "transport_maps = texthash:$P/transport" \
  "recipient_bcc_maps = pcre:$P/recipient_bcc.pcre" \
  "virtual_alias_maps = pcre:$P/virtual.pcre" \
  "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination" \
  "smtpd_recipient_restrictions = reject_non_fqdn_recipient" \
  "alias_maps =" \
  "alias_database =" \
  "smtpd_helo_required = yes" \
  "disable_vrfy_command = yes" \
  "message_size_limit = 157286400" \
  "maximal_queue_lifetime = $QUEUE_LIFETIME" \
  "bounce_queue_lifetime = 2d" \
  "minimal_backoff_time = 120s" \
  "maximal_backoff_time = 900s" \
  "queue_run_delay = 120s" \
  "delay_warning_time = 0" \
  "relayhost = $OUTBOUND_RELAY" \
  "smtp_tls_security_level = may" \
  "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt" \
  "smtp_tls_loglevel = 1" \
  "smtpd_tls_security_level = may" \
  "smtpd_tls_loglevel = 1" \
  "biff = no" \
  "append_dot_mydomain = no" \
  "smtputf8_enable = yes"

if [ -n "${TLS_CERT:-}" ] && [ -n "${TLS_KEY:-}" ]; then
  postconf -e "smtpd_tls_cert_file = $TLS_CERT" "smtpd_tls_key_file = $TLS_KEY" \
              "smtp_tls_cert_file = $TLS_CERT" "smtp_tls_key_file = $TLS_KEY"
else
  postconf -e "smtpd_tls_security_level = none"
fi

# Transport to Exchange Online: its own queue, TLS enforced in production.
postconf -M "exo/unix=exo unix - - n - - smtp"
postconf -P "exo/unix/smtp_tls_security_level=$EXO_TLS_LEVEL" \
            "exo/unix/syslog_name=postfix/exo"

# Transports to the standby nodes: rewrite the shadow address back to the real one.
i=0
for h in $STANDBY_HOSTS; do
  i=$((i+1))
  postconf -M "standby$i/unix=standby$i unix - - n - - smtp"
  postconf -P "standby$i/unix/smtp_generic_maps=pcre:$P/standby_generic.pcre" \
              "standby$i/unix/syslog_name=postfix/standby$i"
done

# Rebuild the recipient list when the provisioner rewrites the file.
(
  last=$(cksum "$RECIPIENTS_FILE")
  while sleep 30; do
    now=$(cksum "$RECIPIENTS_FILE" 2>/dev/null || echo missing)
    if [ "$now" != "$last" ] && [ "$now" != missing ]; then
      build_recipients && postfix reload >/dev/null 2>&1 && echo "zamail-edge: recipient list reloaded"
      last=$now
    fi
  done
) &

postfix check
exec postfix start-fg
