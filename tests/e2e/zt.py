#!/usr/bin/env python3
"""Small test helper for the ZA Mail end-to-end checks. Runs inside the tools container.

  zt.py send <from> <to[,to]> <subject>             send via the edge (as the internet would)
  zt.py submit <user> <password> <to[,to]> <subject> send from the standby as a signed-in user
  zt.py count <standby|exo> <user> <folder> <msgid> number of copies in a mailbox folder
  zt.py wait <standby|exo> <user> <folder> <msgid> <n> [timeout]   wait until count == n
  zt.py append <standby|exo> <user> <folder> <from> <to> <subject>  put a message straight in
  zt.py rcpt <from> <to>                             print the edge's RCPT reply code
  zt.py sink <subject-fragment>                      JSON list of matching mail at the internet sink
"""
import email.utils, imaplib, json, os, smtplib, ssl, sys, time, urllib.request
from email.message import EmailMessage

EDGE = ("172.30.53.10", 25)
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
SYSTEMS = {
    "standby": ("standby", f"{os.environ['STANDBY_SVC_USER']}@corp.test", os.environ["STANDBY_SVC_PASSWORD"]),
    "exo": (os.environ["EXO_IMAP_HOST"], os.environ["EXO_MASTER_USER"], os.environ["EXO_MASTER_PASSWORD"]),
}


def build(sender, rcpts, subject):
    m = EmailMessage()
    m["From"], m["To"], m["Subject"] = sender, ", ".join(rcpts), subject
    m["Date"] = email.utils.formatdate(localtime=True)
    m["Message-ID"] = email.utils.make_msgid(domain=sender.split("@")[1])
    m.set_content(f"ZA Mail test message: {subject}\n")
    return m


def imap(system, user):
    host, master, pw = SYSTEMS[system]
    c = imaplib.IMAP4_SSL(host, 993, ssl_context=CTX)
    c.login(f"{user}%{master}", pw)
    return c


def count(system, user, folder, msgid):
    c = imap(system, user)
    try:
        typ, _ = c.select(f'"{folder}"', readonly=True)
        if typ != "OK":
            return 0
        # Headers are fetched and compared here rather than with IMAP SEARCH, because
        # header search on a freshly delivered message is not reliable on every server.
        typ, data = c.fetch("1:*", "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])")
        if typ != "OK":
            return 0
        return sum(1 for part in data if isinstance(part, tuple) and msgid.encode() in part[1])
    finally:
        c.logout()


def main(a):
    cmd = a[0]
    if cmd == "send":
        m = build(a[1], a[2].split(","), a[3])
        with smtplib.SMTP(*EDGE, timeout=30) as s:
            s.send_message(m)
        print(m["Message-ID"])
    elif cmd == "submit":
        m = build(a[1], a[3].split(","), a[4])
        with smtplib.SMTP_SSL("standby", 465, context=CTX, timeout=30) as s:
            s.login(a[1], a[2])
            s.send_message(m)
        print(m["Message-ID"])
    elif cmd == "count":
        print(count(a[1], a[2], a[3], a[4]))
    elif cmd == "wait":
        want, timeout = int(a[5]), int(a[6]) if len(a) > 6 else 45
        deadline, got = time.time() + timeout, -1
        while time.time() < deadline:
            try:
                got = count(a[1], a[2], a[3], a[4])
            except Exception as e:
                got = f"error: {e}"
            if got == want:
                print(got)
                return 0
            time.sleep(2)
        print(got)
        return 1
    elif cmd == "append":
        m = build(a[4], a[5].split(","), a[6])
        c = imap(a[1], a[2])
        c.append(f'"{a[3]}"', "(\\Seen)", imaplib.Time2Internaldate(time.time()), m.as_bytes())
        c.logout()
        print(m["Message-ID"])
    elif cmd == "rcpt":
        with smtplib.SMTP(*EDGE, timeout=30) as s:
            s.ehlo("sender.example.net")
            s.mail(a[1])
            code, msg = s.rcpt(a[2])
            print(code, msg.decode(errors="replace"))
    elif cmd == "sink":
        with urllib.request.urlopen("http://internet:8025/api/v1/messages?limit=200", timeout=15) as r:
            msgs = json.load(r)["messages"]
        out = []
        for m in msgs:
            if a[1] in m.get("Subject", ""):
                with urllib.request.urlopen(f"http://internet:8025/api/v1/message/{m['ID']}/headers", timeout=15) as r:
                    h = json.load(r)
                out.append({"subject": m["Subject"], "to": [t["Address"] for t in m.get("To") or []],
                            "dkim": bool(h.get("Dkim-Signature") or h.get("DKIM-Signature")),
                            "received": h.get("Received", [])[:1]})
        print(json.dumps(out))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
