#!/usr/bin/env python3
"""ZA Mail mirror: copies mail from Microsoft 365 into the standby mailboxes, so the standby
also holds Sent Items, mail between colleagues, and the user's folders.

  mirror.py              recent mail only (last MIRROR_RECENT_DAYS days); run every 10 minutes
  mirror.py --full       everything; run nightly
  mirror.py --user a@b   one mailbox only

Rules:
  * One-way and additive. It never deletes or moves anything on either side.
  * It does nothing while the outage flag is set, so a half-working Microsoft 365 can never
    damage the standby.
  * No duplicates: the same message usually reaches the standby twice, once from the edge in
    real time and once from here. They are matched on the Message-Id header.
"""
import argparse, os, sys, time
import zimap


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--user")
    a = ap.parse_args()

    flag = os.path.join(zimap.STATE, "outage")
    if os.path.exists(flag):
        print(f"mirror: outage flag is set ({flag}); not syncing")
        return 0
    try:
        people = zimap.users(a.user)
    except OSError:
        print(f"mirror: no user list in {zimap.STATE} (run sync/provision.py)")
        return 1

    token = None
    if os.environ.get("EXO_AUTH", "oauth") == "oauth":
        try:
            token = zimap.exo_token()
        except Exception as e:
            print(f"mirror: cannot get a token from Entra ID ({e}); not syncing")
            return 0

    days = None if a.full else int(os.environ.get("MIRROR_RECENT_DAYS", "3"))
    mode = "full" if a.full else "recent"
    rc = 0
    for u in people:
        src = dst = None
        try:
            src, dst = zimap.connect_exo(u, token), zimap.connect_standby(u)
            copied, there, failed = zimap.copy_mailbox(src, dst, days=days)
            print(f"mirror: {u} {'ok' if not failed else 'PARTIAL'} ({mode}): "
                  f"{copied} copied, {there} already there, {failed} failed")
            rc = rc or (1 if failed else 0)
        except Exception as e:
            print(f"mirror: {u} FAILED: {e}")
            rc = 1
        finally:
            zimap.close(*(c for c in (src, dst) if c))
    with open(os.path.join(zimap.STATE, "mirror-last-run"), "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ\n", time.gmtime()))
    return rc


if __name__ == "__main__":
    sys.exit(main())
