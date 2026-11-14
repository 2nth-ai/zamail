# ZA Mail edge: Postfix MX that relays to Exchange Online and copies to the standby.
FROM alpine:3.22
RUN apk add --no-cache postfix postfix-pcre ca-certificates tzdata
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME /var/spool/postfix
EXPOSE 25
HEALTHCHECK --interval=30s --timeout=5s CMD test -d "/proc/$(cat /var/spool/postfix/pid/master.pid | tr -d ' ')" || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
