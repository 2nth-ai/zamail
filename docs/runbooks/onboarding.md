# Runbook: onboarding a customer

Do the steps in order. Steps 5 and 8 change live mail flow; everything else is preparation.
The Microsoft 365 scripts and the Ansible roles have not been run against live systems yet,
so use `-WhatIf` and a pilot domain the first time.

## Before you start

- Two sites with public IPv4 addresses, port 25 open both ways, and reverse DNS you control.
- A TLS certificate covering both edge hostnames (for example `*.zamail.corp.co.za`).
- DNS for the domain hosted on two providers, neither of them Azure DNS.
- A Microsoft 365 admin who can create connectors and app registrations.
- An SMS or WhatsApp route to all staff that does not depend on Microsoft.

## Steps

1. **Create the app registration.** Put the mailboxes that need continuity in one group,
   then run `exo/New-ZaMailApp.ps1 -MailboxGroup <group>`. Copy the three values it prints
   into `.env`.
2. **Deploy.** Fill in `.env` from `.env.example` and run the Ansible playbook, or on each
   host: `docker compose up -d` in `compose/edge` and `compose/standby`, then
   `bin/standby-init.sh`.
3. **Check provisioning.** `provision.log` should show the expected number of accounts.
   Check `/etc/zamail/recipients` on every edge: a missing address means rejected mail.
4. **Publish DNS that is safe to add early.**
   - A/AAAA records for the edge and standby hostnames, with matching reverse DNS.
   - The standby's DKIM record (shown in the Stalwart admin under the domain's DNS records).
   - Add the edge IPs to the SPF record.
5. **Prepare Exchange Online.** `exo/Set-ZaMailConnector.ps1 -Stage Prepare ...`.
   Nothing is restricted yet.
6. **Test before cut-over.** Send a message straight to an edge for a pilot user
   (`swaks --server mx1... --to pilot@corp.co.za`). It must arrive in Outlook, pass
   Microsoft's spam filtering, and appear in ZA Mail webmail.
7. **Run the first full mirror.** `sync/mirror.py --full`. Large tenants take days because
   Microsoft throttles IMAP; start early.
8. **Cut over MX.** Lower the MX TTL a day ahead. Point MX at the two edges. Watch the
   edge logs and queue.
9. **Enforce.** After the old TTL has expired and mail is flowing through the edges for a
   day: `exo/Set-ZaMailConnector.ps1 -Stage Enforce`.
10. **Enrol every user. This is a gate, not a nice-to-have.** Each user signs in to
    webmail once with their one-time password, sets a new password and a second factor,
    and bookmarks the address. Hand out the passwords from
    `initial-passwords.csv`, then delete the file. Track who has not enrolled.
11. **Rehearse.** Run the failover drill in `failover.md` with a pilot group, and the
    break-glass procedure in `break-glass.md` on paper.

## Every quarter

- Sign-in drill: everyone opens webmail once.
- Rotate the app secret and the ZA Mail service password.
- Read the last mirror and provisioner logs for failures.
- Upgrade Stalwart only after the new version passes `tests/e2e/run.sh` in the development stack.
