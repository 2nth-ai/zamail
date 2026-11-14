# Runbook: Microsoft 365 is down

Nothing needs to be switched. Mail is already arriving on ZA Mail. This runbook is about
telling people and watching the system.

## 1. Confirm

- The probe raises the flag by itself after three failed checks (about three minutes).
  Check: `cat /var/lib/zamail/outage` in the tools container, and `probe.log`.
- Cross-check Microsoft's status page and a news source. One user's problem is not an outage.
- To declare an outage by hand: `echo "raised by <name>" > /var/lib/zamail/outage`.

## 2. Tell staff

The probe runs `PROBE_NOTIFY_CMD` once. If you send the notice by hand, say:

> Microsoft 365 mail is down. Use ZA Mail: https://mail.zamail.corp.co.za
> Sign in with your ZA Mail password. Your recent mail is already there.
> Things you delete or file there will not carry back to Outlook later.

Tell them not to use the new Outlook for Windows; it depends on Microsoft's cloud.

## 3. Watch

| Check | Command | Healthy |
|---|---|---|
| Edge is accepting mail | `docker compose logs edge` | `status=sent` lines for the standby |
| Queue for Microsoft | `docker compose exec edge postqueue -p` | Growing is normal; it drains later |
| Standby | webmail sign-in works | |
| Mirror stood down | `mirror.log` | "outage flag is set; not syncing" |

The edge keeps mail for Microsoft for 10 days (`QUEUE_LIFETIME`). If an outage could last
longer, raise it before day 10: `postconf -e maximal_queue_lifetime=20d && postfix reload`
inside the edge container.

## 4. Users who cannot sign in

They never enrolled, or forgot the password. An admin sets a temporary password in the
Stalwart admin (reach port 8080 through an SSH tunnel) and gives it to them by phone.

## 5. When Microsoft comes back

Do not announce the end yourself on the first good sign. Follow `failback.md`.
