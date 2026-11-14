#!/usr/bin/env python3
"""Fetches an app-only OAuth token for Exchange Online IMAP and writes it to a file.

Needs an Entra app registration with the application permission IMAP.AccessAsApp, a
service principal registered in Exchange Online, and FullAccess on each mailbox
(exo/New-ZaMailApp.ps1 sets all of that up).

  get-token.py <output-file>

Exits non-zero if Entra ID does not issue a token; the mirror then skips its run.
UNTESTED against a live tenant in this repository.
"""
import json, os, sys, urllib.parse, urllib.request

tenant = os.environ["M365_TENANT_ID"]
body = urllib.parse.urlencode({
    "client_id": os.environ["M365_CLIENT_ID"],
    "client_secret": os.environ["M365_CLIENT_SECRET"],
    "grant_type": "client_credentials",
    "scope": "https://outlook.office365.com/.default",
}).encode()
with urllib.request.urlopen(f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token", body, timeout=30) as r:
    token = json.load(r)["access_token"]
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(token)
