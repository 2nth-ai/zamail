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
import argparse, fcntl, os, sys, time
import zimap

ATTEMPTS = 12   # a long first copy outlives tokens and connections; each attempt resumes


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

    # Only one mirror at a time: two running together could add the same message twice.
    os.makedirs(zimap.STATE, exist_ok=True)
    lock = open(os.path.join(zimap.STATE, "mirror.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("mirror: another mirror is already running; skipping this run")
        return 0

    oauth = os.environ.get("EXO_AUTH", "oauth") == "oauth"
    token = None
    if oauth:
        try:
            token = zimap.exo_token()
        except Exception as e:
            print(f"mirror: cannot get a token from Entra ID ({e}); not syncing")
            return 0

    days = None if a.full else int(os.environ.get("MIRROR_RECENT_DAYS", "3"))
    mode = "full" if a.full else "recent"
    rc = 0
    for u in people:
        total = 0
        for attempt in range(1, ATTEMPTS + 1):
            src = dst = None
            try:
                src, dst = zimap.connect_exo(u, token), zimap.connect_standby(u)
                copied, there, failed = zimap.copy_mailbox(src, dst, days=days, log=lambda m: print(m, flush=True))
                total += copied
                print(f"mirror: {u} {'ok' if not failed else 'PARTIAL'} ({mode}): "
                      f"{total} copied, {there} already there, {failed} failed", flush=True)
                rc = rc or (1 if failed else 0)
                break
            except Exception as e:
                # Whatever was copied before the break is kept; the next attempt skips it.
                if attempt == ATTEMPTS:
                    print(f"mirror: {u} FAILED after {attempt} attempts: {e}", flush=True)
                    rc = 1
                    break
                print(f"mirror: {u} interrupted ({e}); resuming, attempt {attempt + 1} of {ATTEMPTS}", flush=True)
                time.sleep(20)
                if oauth:
                    try:
                        token = zimap.exo_token()
                    except Exception:
                        pass
            finally:
                zimap.close(*(c for c in (src, dst) if c))
    with open(os.path.join(zimap.STATE, "mirror-last-run"), "w") as f:
        f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ\n", time.gmtime()))
    return rc


if __name__ == "__main__":
    sys.exit(main())
