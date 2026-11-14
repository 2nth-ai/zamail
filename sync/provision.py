#!/usr/bin/env python3
"""ZA Mail provisioner: keeps the standby directory and the edge recipient list in step
with the customer's directory.

Sources (DIRECTORY_SOURCE):
  file   a JSON file (development, or customers who prefer to export a list)
  graph  Microsoft Graph, app-only (needs User.Read.All and Group.Read.All)

What it does, every run:
  1. Reads users, aliases and distribution lists from the source.
  2. Writes the edge recipient list (the edge rejects mail for anyone not on it).
  3. Creates standby accounts that are missing, with a one-time initial password.
  4. Updates names, aliases and list members on existing entries.

What it never does: reset a password, or delete an account or mailbox. If the source is
unreachable (for example Entra ID is down) it exits without changing anything, so the
last good directory keeps working. Accounts that disappeared upstream are only reported.
"""
import json, os, secrets, subprocess, sys, tempfile, urllib.parse, urllib.request

ENV = os.environ
STATE = ENV.get("ZAMAIL_STATE_DIR", "/var/lib/zamail")
DOMAINS = ENV["ZAMAIL_DOMAINS"].split()


def log(msg):
    print(f"provision: {msg}", flush=True)


# ---------------------------------------------------------------- sources

def from_file():
    with open(ENV["DIRECTORY_FILE"]) as f:
        return json.load(f)


def graph_get(url, token):
    items = []
    while url:
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=30) as r:
            page = json.load(r)
        items += page.get("value", [])
        url = page.get("@odata.nextLink")
    return items


def from_graph():
    """UNTESTED against a live tenant in this repository; see docs/design.md."""
    tenant, cid, secret = ENV["M365_TENANT_ID"], ENV["M365_CLIENT_ID"], ENV["M365_CLIENT_SECRET"]
    body = urllib.parse.urlencode({
        "client_id": cid, "client_secret": secret, "grant_type": "client_credentials",
        "scope": "https://graph.microsoft.com/.default"}).encode()
    with urllib.request.urlopen(
            f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", body, timeout=30) as r:
        token = json.load(r)["access_token"]

    def smtp_addresses(proxy):
        return [p[5:].lower() for p in proxy or [] if p.lower().startswith("smtp:")]

    def ours(addr):
        return addr.rsplit("@", 1)[-1] in DOMAINS

    base = "https://graph.microsoft.com/v1.0"
    users = []
    for u in graph_get(f"{base}/users?$select=mail,displayName,proxyAddresses,accountEnabled&$top=999", token):
        mail = (u.get("mail") or "").lower()
        if not mail or not ours(mail):
            continue
        aliases = [a for a in smtp_addresses(u.get("proxyAddresses")) if a != mail and ours(a)]
        users.append({"mail": mail, "displayName": u.get("displayName") or mail, "aliases": aliases})
    lists = []
    for g in graph_get(f"{base}/groups?$filter=mailEnabled eq true&$select=id,mail,displayName&$top=999", token):
        mail = (g.get("mail") or "").lower()
        if not mail or not ours(mail):
            continue
        members = graph_get(f"{base}/groups/{g['id']}/transitiveMembers/microsoft.graph.user?$select=mail&$top=999", token)
        lists.append({"mail": mail, "displayName": g.get("displayName") or mail,
                      "members": sorted({(m.get("mail") or "").lower() for m in members if m.get("mail")})})
    return {"users": users, "lists": lists}


# ---------------------------------------------------------------- standby

def cli(*args, stdin=None):
    env = dict(ENV, STALWART_URL=ENV["STANDBY_URL"], STALWART_USER="admin",
               STALWART_PASSWORD=ENV["STANDBY_RECOVERY_PASSWORD"])
    if ENV.get("STANDBY_ADMIN_USER"):
        env.update(STALWART_USER=ENV["STANDBY_ADMIN_USER"], STALWART_PASSWORD=ENV["STANDBY_ADMIN_PASSWORD"])
    p = subprocess.run(["stalwart-cli", *args], input=stdin, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise RuntimeError(f"stalwart-cli {' '.join(args[:3])}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout


def query(obj):
    return [json.loads(line) for line in cli("query", obj, "--json").splitlines() if line.strip().startswith("{")]


def split(addr):
    local, domain = addr.lower().rsplit("@", 1)
    return local, domain


def write_recipients(directory):
    path = ENV.get("RECIPIENTS_FILE", "/etc/zamail/recipients")
    addrs = set()
    for u in directory["users"]:
        addrs.add(u["mail"].lower())
        addrs.update(a.lower() for a in u.get("aliases", []))
    for l in directory.get("lists", []):
        addrs.add(l["mail"].lower())
    if not addrs:
        raise RuntimeError("directory is empty; refusing to write an empty recipient list")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        f.write("# Written by sync/provision.py. One valid recipient per line.\n")
        f.write("\n".join(sorted(addrs)) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    log(f"edge recipient list: {len(addrs)} addresses")


def main():
    source = ENV.get("DIRECTORY_SOURCE", "file")
    try:
        directory = from_graph() if source == "graph" else from_file()
    except Exception as e:  # source down: keep the last good state
        log(f"directory source '{source}' unavailable ({e}); nothing changed")
        return 0

    write_recipients(directory)

    domain_ids = {d["name"]: d["id"] for d in query("Domain")}
    accounts = {a["emailAddress"].lower(): a["id"] for a in query("Account") if a.get("emailAddress")}
    lists = {l["emailAddress"].lower(): l["id"] for l in query("MailingList") if l.get("emailAddress")}

    def alias_map(aliases):
        out = {}
        for i, a in enumerate(sorted(aliases)):
            local, domain = split(a)
            if domain in domain_ids:
                out[str(i)] = {"name": local, "domainId": domain_ids[domain]}
        return out

    created = updated = 0
    new_passwords = []
    for u in directory["users"]:
        mail = u["mail"].lower()
        local, domain = split(mail)
        if domain not in domain_ids:
            log(f"skip {mail}: domain not configured on the standby")
            continue
        body = {"description": u.get("displayName") or mail, "aliases": alias_map(u.get("aliases", []))}
        if mail in accounts:
            cli("update", "Account", accounts[mail], "--json", json.dumps(body))
            updated += 1
        else:
            password = u.get("initialPassword") or secrets.token_urlsafe(18)
            body.update({"name": local, "domainId": domain_ids[domain], "roles": {"@type": "User"},
                         "credentials": {"0": {"@type": "Password", "secret": password}}})
            cli("create", "Account/User", "--json", json.dumps(body))
            if not u.get("initialPassword"):
                new_passwords.append((mail, password))
            created += 1

    for l in directory.get("lists", []):
        mail = l["mail"].lower()
        local, domain = split(mail)
        if domain not in domain_ids:
            continue
        body = {"description": l.get("displayName") or mail,
                "recipients": {m.lower(): True for m in l.get("members", [])}}
        if mail in lists:
            cli("update", "MailingList", lists[mail], "--json", json.dumps(body))
        else:
            body.update({"name": local, "domainId": domain_ids[domain]})
            cli("create", "MailingList", "--json", json.dumps(body))

    if new_passwords:
        os.makedirs(STATE, exist_ok=True)
        path = os.path.join(STATE, "initial-passwords.csv")
        with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "a") as f:
            for mail, pw in new_passwords:
                f.write(f"{mail},{pw}\n")
        log(f"{len(new_passwords)} initial passwords appended to {path} (hand out, then delete the file)")

    upstream = {u["mail"].lower() for u in directory["users"]}
    svc = {f"{ENV.get('STANDBY_SVC_USER', 'zamail-svc')}@{d}" for d in DOMAINS} | {f"admin@{d}" for d in DOMAINS}
    stale = sorted(set(accounts) - upstream - svc)
    if stale:
        log("no longer in the directory (left untouched, review by hand): " + ", ".join(stale))
    log(f"accounts: {created} created, {updated} updated; lists: {len(directory.get('lists', []))}")

    # user list for the mirror
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "users"), "w") as f:
        f.write("\n".join(sorted(upstream)) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
