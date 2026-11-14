#!/usr/bin/env python3
"""ZA Mail fail-back: after Microsoft 365 is healthy again, copies what happened on the
standby during the outage back into the Microsoft 365 mailboxes.

  failback.py --days N [--user a@b] [--dry-run]

  N = how many days back to look; use the outage length plus one.

What is copied: Inbox and Sent Items only, messages from the last N days, additive.
  * Sent Items: everything users sent from ZA Mail during the outage.
  * Inbox: mail between colleagues that was delivered on the standby and never passed the
    edge. Mail from outside is already arriving from the edge queue, and the Message-Id
    comparison stops it being added twice.
What is not copied: read/unread changes, deletions, folder moves made on the standby.

Run it only after the edge queue for Exchange Online has drained (see the runbook),
otherwise outside mail could arrive twice.
"""
import argparse, os, sys
import zimap


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, required=True)
    ap.add_argument("--user")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    token = None
    if os.environ.get("EXO_AUTH", "oauth") == "oauth":
        try:
            token = zimap.exo_token()
        except Exception as e:
            print(f"failback: cannot get a token from Entra ID ({e}); nothing done")
            return 1

    rc = 0
    for u in zimap.users(a.user):
        src = dst = None
        try:
            src, dst = zimap.connect_standby(u), zimap.connect_exo(u, token)
            copied, there, failed = zimap.copy_mailbox(
                src, dst, days=a.days, only_special={"\\sent"}, dry_run=a.dry_run,
                log=lambda m: print(f"failback: {u}{m}"))
            verb = "would copy" if a.dry_run else "copied"
            print(f"failback: {u} {'ok' if not failed else 'PARTIAL'}: "
                  f"{verb} {copied}, {there} already there, {failed} failed")
            rc = rc or (1 if failed else 0)
        except Exception as e:
            print(f"failback: {u} FAILED: {e}")
            rc = 1
        finally:
            zimap.close(*(c for c in (src, dst) if c))
    return rc


if __name__ == "__main__":
    sys.exit(main())
