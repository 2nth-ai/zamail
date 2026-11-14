#!/usr/bin/env python3
"""ZA Mail probe: decides whether Microsoft 365 mail is up, and raises the outage flag.

Run it every minute from cron or a systemd timer, on a ZA Mail host (never on Microsoft
infrastructure). Each run performs these checks:

  smtp   connect to the tenant's Exchange Online endpoint and complete EHLO
  login  get a token from Entra ID and sign in to a canary mailbox over IMAP
         (development: master login to the mock server)

PROBE_CHECKS chooses which to run (default "smtp login"). Use "login" alone on hosts that
cannot make outbound connections on port 25, such as Google Cloud VMs.

State lives in $ZAMAIL_STATE_DIR:
  probe.json   consecutive failure / success counters and last results
  outage       the outage flag. While it exists the mirror does not run.

Rules:
  * The flag is RAISED automatically after PROBE_FAIL_THRESHOLD consecutive failed runs
    (default 3). Either check failing counts: a sign-in outage is an outage for users.
  * The flag is NEVER cleared automatically. A person clears it during fail-back
    (docs/runbooks/failback.md), because Microsoft 365 often flaps while recovering.
  * PROBE_NOTIFY_CMD, if set, is run with one argument: "outage" when the flag is
    raised, "recovering" when checks pass again PROBE_OK_THRESHOLD times in a row.
    Point it at an SMS or WhatsApp gateway. Email and Teams are no use for this.
"""
import imaplib, json, os, smtplib, ssl, subprocess, sys, time

ENV = os.environ
STATE = ENV.get("ZAMAIL_STATE_DIR", "/var/lib/zamail")
FAIL_N = int(ENV.get("PROBE_FAIL_THRESHOLD", "3"))
OK_N = int(ENV.get("PROBE_OK_THRESHOLD", "5"))
FLAG = os.path.join(STATE, "outage")
STATE_FILE = os.path.join(STATE, "probe.json")


def check_smtp():
    with smtplib.SMTP(ENV["EXO_SMTP_HOST"], int(ENV.get("EXO_SMTP_PORT", "25")), timeout=20) as s:
        code, _ = s.ehlo(ENV.get("PROBE_EHLO_NAME", "probe.zamail.invalid"))
        if code != 250:
            raise RuntimeError(f"EHLO answered {code}")


def check_login():
    ctx = ssl.create_default_context()
    if ENV.get("IMAP_TLS_VERIFY", "true") == "false":
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    user = ENV["EXO_CANARY_USER"]
    c = imaplib.IMAP4_SSL(ENV.get("EXO_IMAP_HOST", "outlook.office365.com"), 993, ssl_context=ctx, timeout=20)
    try:
        if ENV.get("EXO_AUTH", "oauth") == "oauth":
            token_file = os.path.join(STATE, "probe-token")
            subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "..", "sync", "get-token.py"),
                            token_file], check=True, timeout=40)
            token = open(token_file).read()
            c.authenticate("XOAUTH2", lambda _: f"user={user}\x01auth=Bearer {token}\x01\x01".encode())
        else:
            c.login(f"{user}%{ENV['EXO_MASTER_USER']}", ENV["EXO_MASTER_PASSWORD"])
        typ, _ = c.select("INBOX", readonly=True)
        if typ != "OK":
            raise RuntimeError("could not open the canary inbox")
    finally:
        try:
            c.logout()
        except Exception:
            pass


def notify(event):
    cmd = ENV.get("PROBE_NOTIFY_CMD")
    if cmd:
        subprocess.run([cmd, event], timeout=60, check=False)


def main():
    os.makedirs(STATE, exist_ok=True)
    try:
        st = json.load(open(STATE_FILE))
    except Exception:
        st = {"fails": 0, "oks": 0}

    results = {}
    wanted = ENV.get("PROBE_CHECKS", "smtp login").split()
    for name, fn in (("smtp", check_smtp), ("login", check_login)):
        if name not in wanted:
            continue
        try:
            fn()
            results[name] = "ok"
        except Exception as e:
            results[name] = f"FAIL: {e}"
    healthy = all(v == "ok" for v in results.values())

    st["fails"] = 0 if healthy else st.get("fails", 0) + 1
    st["oks"] = st.get("oks", 0) + 1 if healthy else 0
    st.update(last=results, at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))

    flagged = os.path.exists(FLAG)
    if not healthy and st["fails"] >= FAIL_N and not flagged:
        with open(FLAG, "w") as f:
            f.write(f"raised {st['at']} by probe: {json.dumps(results)}\n")
        notify("outage")
        print(f"probe: OUTAGE flag raised after {st['fails']} failed runs: {results}")
    elif healthy and flagged and st["oks"] == OK_N:
        notify("recovering")
        print("probe: Microsoft 365 looks healthy again; flag stays until a person clears it")
    else:
        print(f"probe: {'healthy' if healthy else 'unhealthy'} {results} "
              f"(fails={st['fails']}, oks={st['oks']}, flag={'set' if flagged else 'clear'})")

    json.dump(st, open(STATE_FILE, "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
