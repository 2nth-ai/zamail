# Security

ZA Mail handles an organisation's email, so security reports are taken seriously.

## Reporting a problem

Do not open a public issue. Use GitHub's private reporting instead: on the repository
page, choose **Security**, then **Report a vulnerability**.

Include what you found, how to reproduce it, and which version or commit you used.

## What to expect

This is a volunteer-maintained project without a guaranteed response time. Reports are
acknowledged as soon as a maintainer sees them, and fixes are credited unless you ask
otherwise.

## Scope

In scope: this repository's code and configuration (the edge configuration, setup scripts,
provisioner, mirror, fail-back, probe, Microsoft 365 scripts).

Out of scope: vulnerabilities in Postfix, Stalwart or Roundcube themselves. Report those
to their projects.

## Things operators must protect

- The Microsoft 365 app secret and the ZA Mail service account password. Each can open
  every mailbox it covers.
- The standby's admin port (8080) and intake port (25). Neither may face the internet.
- The development passwords in `compose/dev/` are public. Never reuse them.
