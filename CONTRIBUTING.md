# Contributing to ZA Mail

ZA Mail is young. The mail path works in the local development stack; much of the
production side has not yet been proven against real systems. Reports from real
deployments are the most valuable contribution right now.

## Where help is most needed

| Area | What is needed |
|---|---|
| Microsoft 365 | Run `exo/` scripts and the Graph provisioner against a real tenant; report what breaks. |
| Real hosts | Run the Ansible roles and production Compose files on Linux servers. |
| Recipient list sync | Copy `/etc/zamail/recipients` from the standby host to edges on other hosts. |
| Sending reputation | The outbound warm-up route (design section 8). |
| Calendars and contacts | Sync from Microsoft 365 into the standby. |
| Other providers | Google Workspace as the primary system instead of Microsoft 365. |
| Hosting notes | Experience with specific South African data centres and providers. |

## Getting set up

You need Docker. Then:

```
bin/dev-up.sh
tests/e2e/run.sh
```

Both test suites must pass before you open a pull request, and a change in behaviour
needs a test that shows it.

## Rules the code keeps

These are the safety properties of the design. A change that weakens one needs a very good
reason and its own discussion.

1. The edge never modifies a message.
2. The mirror and fail-back only add. Nothing in ZA Mail deletes mail.
3. Nothing runs against Microsoft 365 while the outage flag is set, and only a person
   clears the flag.
4. Sign-in to ZA Mail never depends on Microsoft.
5. Every component has an OSI-approved licence.

## Pull requests

- Keep each pull request to one change.
- Say what you tested and how. "Not tested against a live tenant" is a fine thing to say;
  claiming more than you tested is not.
- Update `docs/design.md` section 13 when you prove or build something listed there.
- Never commit real domains, tenant IDs, passwords or mail.

By contributing you agree that your contribution is licensed under Apache-2.0.
