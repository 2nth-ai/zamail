# Ansible deployment

**Not yet run against real hosts.** These roles lay the kit down on Linux servers; treat the
first run as a test.

Layout per customer: two sites (for example Johannesburg and Cape Town), each with one
`edge` host and one `standby` host. A small customer can put both roles on one host per site.

```
ansible-playbook -i inventory/hosts.yml site.yml --limit customer_corp
```

`inventory/group_vars/all.yml` holds the customer's settings; secrets belong in Ansible Vault.
The playbook copies the repository to `/opt/zamail`, writes `/opt/zamail/.env`, and starts
the Compose projects. Run `bin/standby-init.sh` on each standby afterwards (the role does
this on first install).
