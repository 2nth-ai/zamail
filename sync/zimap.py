"""ZA Mail IMAP copier: the small library behind the mirror and fail-back.

It copies messages from one IMAP mailbox to another and keeps three promises:

  * Additive only. It never deletes, moves or changes a message on either side.
  * No duplicates. A message already present in the destination folder is skipped. Messages
    are matched on their Message-Id header (or, when that is missing, on a hash of the Date,
    From and Subject headers).
  * Folder by folder. A failure in one folder or one message does not stop the rest.

Python standard library only.
"""
import hashlib, imaplib, os, re, ssl, subprocess, sys, time
from datetime import datetime, timedelta, timezone

ENV = os.environ
STATE = ENV.get("ZAMAIL_STATE_DIR", "/var/lib/zamail")
HERE = os.path.dirname(os.path.abspath(__file__))

# Folders that are never copied: not mail, or mail nobody wants during an outage.
SKIP_SPECIAL = {"\\trash", "\\junk", "\\drafts", "\\all", "\\noselect", "\\nonexistent"}
SKIP_NAMES = re.compile(
    r"^(Deleted Items|Junk Email|Junk Mail|Drafts|Outbox|Conversation History|Sync Issues.*|All Mail|"
    r"Calendar.*|Contacts.*|Tasks|Notes|Journal|RSS Feeds|Archive Mailbox.*)$", re.I)
KEEP_FLAGS = {"\\seen", "\\answered", "\\flagged"}
BATCH = 200


def tls_context(setting="IMAP_TLS_VERIFY"):
    """TLS settings. IMAP_TLS_VERIFY governs the Microsoft 365 side and must stay "true" in
    production. STANDBY_TLS_VERIFY governs the hop to our own standby, which is often
    reached by a private name that its public certificate does not cover."""
    ctx = ssl.create_default_context()
    if ENV.get(setting, "true") == "false":
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    return ctx


def exo_token():
    """App-only OAuth token for Exchange Online, fetched once per run."""
    path = os.path.join(STATE, "exo-token")
    subprocess.run([sys.executable, os.path.join(HERE, "get-token.py"), path], check=True, timeout=60)
    with open(path) as f:
        return f.read()


def xoauth2(conn, user, token):
    """XOAUTH2 sign-in. When the server refuses, it sends an error as a second challenge and
    waits for an empty reply; answering with the token again would hang until timeout."""
    sent = []

    def respond(_challenge):
        sent.append(1)
        return f"user={user}\x01auth=Bearer {token}\x01\x01".encode() if len(sent) == 1 else b""
    conn.authenticate("XOAUTH2", respond)


def connect_exo(user, token=None):
    """Microsoft 365 side. EXO_AUTH=oauth in production, master against the development mock."""
    c = imaplib.IMAP4_SSL(ENV.get("EXO_IMAP_HOST", "outlook.office365.com"), 993,
                          ssl_context=tls_context(), timeout=120)
    if ENV.get("EXO_AUTH", "oauth") == "oauth":
        xoauth2(c, user, token)
    else:
        c.login(f"{user}%{ENV['EXO_MASTER_USER']}", ENV["EXO_MASTER_PASSWORD"])
    return c


def connect_standby(user):
    """ZA Mail side: the service account opens the mailbox by master login."""
    c = imaplib.IMAP4_SSL(ENV["STANDBY_HOST"], 993, ssl_context=tls_context("STANDBY_TLS_VERIFY"), timeout=120)
    domain = user.rsplit("@", 1)[1]
    c.login(f"{user}%{ENV.get('STANDBY_SVC_USER', 'zamail-svc')}@{domain}", ENV["STANDBY_SVC_PASSWORD"])
    return c


_LIST = re.compile(rb'\((?P<flags>[^)]*)\) (?P<delim>"[^"]*"|NIL) (?P<name>.*)')


def folders(conn):
    """Returns [(name, delimiter, {lower-cased flags})] for every folder."""
    typ, data = conn.list()
    out = []
    for line in data or []:
        if isinstance(line, tuple):          # name sent as a literal
            line = line[0] + b' "' + line[1] + b'"'
        m = _LIST.match(line or b"")
        if not m:
            continue
        name = m.group("name").decode().strip()
        if name.startswith('"') and name.endswith('"'):
            name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        delim = m.group("delim").decode().strip('"')
        out.append((name, "" if delim == "NIL" else delim, {f.lower() for f in m.group("flags").decode().split()}))
    return out


def q(name):
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _key(header_bytes):
    """Identity of a message for duplicate detection."""
    text = header_bytes.decode("utf-8", "replace")
    unfolded = re.sub(r"\r?\n[ \t]+", " ", text)
    fields = {}
    for line in unfolded.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip().lower()] = v.strip()
    mid = fields.get("message-id", "")
    if mid:
        return "id:" + mid
    basis = "|".join(fields.get(k, "") for k in ("date", "from", "subject"))
    return "h:" + hashlib.sha1(basis.encode()).hexdigest() if basis.strip("|") else None


def _uids(conn, since):
    criteria = ["ALL"] if since is None else ["SINCE", since.strftime("%d-%b-%Y")]
    typ, data = conn.uid("SEARCH", None, *criteria)
    return data[0].split() if typ == "OK" and data and data[0] else []


def _keys(conn, uids):
    """Maps dedupe key -> uid for the given messages in the selected folder."""
    out = {}
    for i in range(0, len(uids), BATCH):
        chunk = b",".join(uids[i:i + BATCH]).decode()
        typ, data = conn.uid("FETCH", chunk, "(BODY.PEEK[HEADER.FIELDS (MESSAGE-ID DATE FROM SUBJECT)])")
        if typ != "OK":
            continue
        for n, part in enumerate(data):
            if not isinstance(part, tuple):
                continue
            meta = part[0] + (data[n + 1] if n + 1 < len(data) and isinstance(data[n + 1], bytes) else b"")
            m = re.search(rb"UID (\d+)", meta)
            k = _key(part[1])
            if m and k:
                out[k] = m.group(1)
    return out


def _fetch_full(conn, uid):
    typ, data = conn.uid("FETCH", uid.decode(), "(FLAGS INTERNALDATE BODY.PEEK[])")
    if typ != "OK":
        return None
    body, meta = None, b""
    for part in data:
        if isinstance(part, tuple):
            meta += part[0]
            body = part[1]
        elif isinstance(part, bytes):
            meta += part
    if body is None:
        return None
    flags = [f.decode() for f in imaplib.ParseFlags(meta) if f.decode().lower() in KEEP_FLAGS]
    when = imaplib.Internaldate2tuple(meta) or time.localtime()
    return flags, when, body


def copy_mailbox(src, dst, days=None, only_special=None, dry_run=False, log=print):
    """Copies src -> dst. Returns (copied, already_there, failed).

    days          only messages from the last N days (None = everything)
    only_special  restrict to INBOX plus folders with these special-use flags, e.g. {"\\sent"}
    """
    since = None if days is None else datetime.now(timezone.utc) - timedelta(days=days)
    # The destination window is wider than the source window, because the two copies of a
    # message can carry slightly different arrival dates.
    dst_since = None if since is None else since - timedelta(days=3)

    dst_folders = folders(dst)
    dst_names = {n for n, _, _ in dst_folders}
    dst_delim = next((d for _, d, _ in dst_folders if d), "/")
    dst_special = {f: n for n, _, fl in dst_folders for f in fl if f in ("\\sent", "\\archive")}

    copied = skipped = failed = 0
    for name, delim, flags in folders(src):
        if flags & SKIP_SPECIAL or SKIP_NAMES.match(name.split(delim)[-1] if delim else name):
            continue
        is_inbox = name.upper() == "INBOX"
        if only_special is not None and not is_inbox and not (flags & only_special):
            continue

        # Same folder on the other side: match Sent by its role, everything else by name.
        target = "INBOX" if is_inbox else name
        for role in ("\\sent", "\\archive"):
            if role in flags and role in dst_special:
                target = dst_special[role]
        if target == name and delim and delim != dst_delim:
            target = name.replace(delim, dst_delim)

        try:
            if src.select(q(name), readonly=True)[0] != "OK":
                continue
            src_keys = _keys(src, _uids(src, since))
            if not src_keys:
                continue
            if target not in dst_names:
                if dry_run:
                    log(f"  would create folder {target}")
                else:
                    dst.create(q(target))
                    dst.subscribe(q(target))
                dst_names.add(target)
                have = set()
            else:
                dst.select(q(target), readonly=True)
                have = set(_keys(dst, _uids(dst, dst_since)))
            missing = [(k, u) for k, u in src_keys.items() if k not in have]
            skipped += len(src_keys) - len(missing)
            for k, uid in missing:
                if dry_run:
                    copied += 1
                    continue
                msg = _fetch_full(src, uid)
                if msg is None:
                    failed += 1
                    continue
                msg_flags, when, body = msg
                typ, _ = dst.append(q(target), "(" + " ".join(msg_flags) + ")", imaplib.Time2Internaldate(when), body)
                if typ == "OK":
                    copied += 1
                else:
                    failed += 1
            if missing:
                log(f"  {name} -> {target}: {len(missing)} {'to copy' if dry_run else 'copied'}")
        except (imaplib.IMAP4.error, OSError) as e:
            failed += 1
            log(f"  {name}: error: {e}")
            if isinstance(e, (imaplib.IMAP4.abort, OSError)):
                raise
    return copied, skipped, failed


def users(only=None):
    if only:
        return [only]
    with open(os.path.join(STATE, "users")) as f:
        return [u.strip() for u in f if u.strip()]


def close(*conns):
    for c in conns:
        try:
            c.logout()
        except Exception:
            pass
