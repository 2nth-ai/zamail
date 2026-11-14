#!/bin/sh
# Configures a Stalwart server from the command line, with no web wizard.
# Runs inside the ZA Mail tools image.
#
#   stalwart-setup.sh bootstrap <url> <recovery-password> <hostname> <primary-domain> <acme:true|false>
#       First boot only. Exits 10 if the server was bootstrapped and must be restarted,
#       0 if it was already set up.
#   stalwart-setup.sh apply <url> <recovery-password> <plan-template>...
#       Applies plan templates (environment variables are substituted). Safe to re-run.
set -eu

cmd="$1"; url="$2"; pw="$3"; shift 3
export STALWART_URL="$url" STALWART_USER=admin STALWART_PASSWORD="$pw"

wait_up() {
  i=0
  until curl -s -o /dev/null --max-time 3 "$url/"; do
    i=$((i+1)); [ $i -gt 60 ] && { echo "setup: $url did not come up" >&2; exit 1; }
    sleep 2
  done
}

case "$cmd" in
  bootstrap)
    hostname="$1"; domain="$2"; acme="$3"
    wait_up
    if stalwart-cli get Bootstrap --json >/dev/null 2>&1; then
      stalwart-cli update Bootstrap --json "{
        \"defaultHostname\": \"$hostname\",
        \"defaultDomain\": \"$domain\",
        \"requestTlsCertificate\": $acme,
        \"generateDkimKeys\": true,
        \"tracer\": {\"@type\":\"Stdout\",\"enable\":true,\"level\":\"info\",\"lossy\":false,
                     \"ansi\":false,\"multiline\":false,\"events\":{},\"eventsPolicy\":\"exclude\"}
      }" >/dev/null
      echo "setup: $url bootstrapped for $domain; restart required"
      exit 10
    fi
    echo "setup: $url already bootstrapped"
    ;;
  apply)
    wait_up
    for tmpl in "$@"; do
      echo "setup: applying $(basename "$tmpl") to $url"
      envsubst < "$tmpl" | grep -v '^[[:space:]]*\(//\|$\)' | stalwart-cli apply --stdin --quiet
    done
    stalwart-cli create Action/ReloadSettings --json '{}' >/dev/null
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2 ;;
esac
