# Runbook: break-glass (ZA Mail itself is failing)

Use this when ZA Mail is the problem and Microsoft 365 is healthy: both edges are down, or
the edge is rejecting or losing mail. It takes ZA Mail out of the mail path.

Until you act, inbound mail is not lost. Senders retry, typically for 4–5 days. Mail
inside Microsoft 365 is unaffected.

## One edge down

Nothing to do for mail flow. Senders use the other MX. Repair the edge.

## Both edges down, or the edge is misbehaving

1. **Lift the restriction in Exchange Online** so Microsoft accepts mail directly:
   `exo/Set-ZaMailConnector.ps1 -Stage Release`
2. **Point MX back at Microsoft** on both DNS providers:
   `corp-co-za.mail.protection.outlook.com`, priority 0. Keep the TTL low (300 s).
3. **Check** with a message from an outside account. It should arrive in Outlook within
   the TTL.
4. If an edge is running but cut off from Microsoft, its queue still holds mail. Keep the
   host and its `edge-spool` volume. When it can reach Microsoft again, run
   `postqueue -f`. Never delete the queue volume.

While MX points at Microsoft the standby receives no new inbound copies. The mirror still
brings mail across every 10 minutes, so the standby stays roughly current.

## Returning to normal

1. Fix and test the edges (send a test message straight to each edge).
2. Point MX back at the edges. Wait out the TTL.
3. `exo/Set-ZaMailConnector.ps1 -Stage Enforce`
4. Run `sync/mirror.py --full` once to fill any gap.

## Rehearse this

Walk through it on paper at onboarding and once a year. The people who can change DNS and
Exchange connectors must be reachable without email.
