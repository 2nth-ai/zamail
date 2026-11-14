# Runbook: returning to Microsoft 365

Microsoft 365 often flaps while it recovers, so a person decides when the outage is over.
The probe only reports "recovering".

## 1. Decide

- Microsoft has declared the incident resolved, and
- the probe has been healthy for at least 30 minutes (`probe.log`), and
- a pilot user can send and receive in Outlook.

## 2. Let the edge queue drain

```
docker compose exec edge postqueue -f      # try everything now
docker compose exec edge postqueue -p      # repeat until "Mail queue is empty"
```

Do this on both edges. Do not continue while mail for Microsoft is still queued, or
outside mail could be added to mailboxes twice.

## 3. Tell staff to go back to Outlook

> Microsoft 365 mail is working again. Please go back to Outlook now and stop using
> ZA Mail. Mail you sent from ZA Mail will appear in Outlook within the hour.

Wait until people have actually stopped (15 minutes is usually enough).

## 4. Copy outage-time mail back

In the tools container, with N = the outage length in days plus one:

```
python3 /zamail/sync/failback.py --days N --dry-run     # look at the logs first
python3 /zamail/sync/failback.py --days N
```

This adds to Microsoft 365: everything sent from ZA Mail, and mail between colleagues that
was delivered on ZA Mail. It is safe to run twice. It does not copy read state, deletions
or folder moves.

On a dual-standby install, run it on the node users were working on.

## 5. Clear the flag

```
rm /var/lib/zamail/outage
python3 /zamail/sync/mirror.py        # should report each mailbox "ok"
```

## 6. Afterwards

- Spot-check three users: outage-time sent mail is in Outlook's Sent Items.
- Note the timeline, the peak queue size and any users who could not sign in.
- Fix whatever the outage exposed before the next one.
