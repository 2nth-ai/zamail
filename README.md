# ZA Mail

[![CI](https://github.com/2nth-ai/zamail/actions/workflows/ci.yml/badge.svg)](https://github.com/2nth-ai/zamail/actions/workflows/ci.yml)

A second, independent mail system for organisations whose email is on Microsoft 365. It runs
beside Microsoft 365 in a South African data centre or on-premise, and takes over when
Microsoft is down. Open-source components only.

- The domain's MX points at ZA Mail, so inbound mail keeps arriving during a Microsoft outage.
- Every inbound message goes to both the Microsoft 365 mailbox and a ZA Mail mailbox.
- During an outage staff open ZA Mail webmail. Their mail is already there. No DNS change.
- Sign-in does not depend on Entra ID.

Start with the [design document](docs/design.md). Operating procedures are in
[docs/runbooks](docs/runbooks/).

## Try it locally

Needs Docker. Everything runs on your machine; no real mail is sent.

```
bin/dev-up.sh        # builds, starts and configures the stack (a few minutes the first time)
tests/e2e/run.sh     # end-to-end checks, including a simulated Microsoft outage
```

The development stack has ZA Mail itself plus two stand-ins:

| Container | Plays | Look at it |
|---|---|---|
| `edge` | ZA Mail edge, the MX (Postfix) | SMTP on `localhost:2525` |
| `standby` | ZA Mail mailboxes (Stalwart) | admin: http://localhost:8081 |
| `webmail` | ZA Mail webmail (Roundcube) | http://localhost:8088 |
| `mock-exo` | Exchange Online | admin: http://localhost:8082 |
| `internet` | The rest of the internet, for outbound mail | http://localhost:8025 |
| `tools` | Setup, provisioner, mirror, probe, tests | |

Sign in to webmail as `alice@corp.test` with `dev-Alice-Standby-Protea-58`. All
development passwords are in `compose/dev/` and are for the local stack only.

To simulate an outage by hand: `docker compose -f compose/dev/docker-compose.yml stop mock-exo`,
send mail to `alice@corp.test` on port 2525, and read it in webmail.

To remove the stack and its data: `docker compose -f compose/dev/docker-compose.yml down -v`.

## Test status

Last run on 14 November 2026, on macOS with Docker, against the development stack:

| Suite | Result | Covers |
|---|---|---|
| `tests/e2e/phase1.sh` | 16 of 16 passed | Dual delivery, alias and list delivery, unknown-recipient and open-relay rejection, queueing while "Exchange Online" is down, sending from ZA Mail with DKIM, drain on recovery with no duplicates |
| `tests/e2e/phase2.sh` | 12 of 12 passed | Mirror of Sent Items, no duplicates, probe raising the outage flag, mirror standing down, fail-back of outage-time mail, safe to repeat |

Also checked by hand: a copy the standby refuses does not bounce to the original sender,
and webmail sign-in works.

These tests use a mock Exchange Online (a second mail server). They do not prove anything
about a real Microsoft 365 tenant: connectors, OAuth and Graph are untested.

## What is in the repository

| Path | What it is |
|---|---|
| `docs/design.md` | Architecture, mail flow, Microsoft 365 setup, hosting, risks, status |
| `docs/runbooks/` | Onboarding, failover, fail-back, break-glass |
| `compose/edge/` | The edge: Postfix image and its configuration script |
| `compose/standby/` | The standby: Stalwart, Roundcube and scheduled jobs |
| `compose/dev/` | The local development stack |
| `stalwart/plan/` | Stalwart configuration, applied by `bin/stalwart-setup.sh` |
| `sync/` | Provisioner, mirror, fail-back, OAuth token helper |
| `probe/` | Outage detection and notification hook |
| `exo/` | PowerShell for the Microsoft 365 side |
| `ansible/` | Roles to deploy to real hosts |
| `tests/e2e/` | End-to-end tests |
| `site/` | The marketing page (a single static HTML file) |
| `docs/press/` | Draft press release |

## Deploying for real

Follow [docs/runbooks/onboarding.md](docs/runbooks/onboarding.md). Be aware of what has
and has not been proven: section 13 of the design document lists each part. In short, the
mail path is tested locally; the Microsoft 365 scripts, the Graph provisioner and the
Ansible roles are written but have not yet been run against live systems.

## Licences of the components

| Component | Licence |
|---|---|
| Postfix | IBM Public License 1.0 / Eclipse Public License 2.0 |
| Stalwart (Community edition) | AGPL-3.0 |
| Roundcube | GPL-3.0-or-later |
| Mailpit (development only) | MIT |

ZA Mail's own code and documentation are licensed under [Apache-2.0](LICENSE). You may
host it, change it, and offer it as a service, for free. The components above keep their
own licences; ZA Mail runs them unmodified as separate programs.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; it
lists where help is most needed. Report security problems privately as described in
[SECURITY.md](SECURITY.md).

ZA Mail is not affiliated with or endorsed by Microsoft. Microsoft 365, Exchange Online,
Outlook, Teams and Entra ID are trademarks of Microsoft Corporation.
