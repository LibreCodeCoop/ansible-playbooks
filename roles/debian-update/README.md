# Debian package updates (explicitly approved only)

The role never restarts a host. Its default is read-only: it checks the
Debian/Ubuntu reboot-required flag and reports the result.

Package upgrades are disabled by default. When a customer and an authorized
LibreCode operator approve a maintenance window, run for **one host**,
recording the issue/reference and responsible operator. Verify the approval
outside Ansible; variable values cannot prove authorization.

Example (not a deployment authorization):

```sh
ansible-playbook -i inventory.ini debian-update.yml \
  -l approved-host.example.net \
  -e debian_update_target_host=approved-host.example.net \
  -e debian_update_apply=true \
  -e debian_update_change_ref=APPROVED-ISSUE-REFERENCE \
  -e debian_update_approved_by=APPROVED-OPERATOR
```

The role performs an opt-in dist-upgrade (which may restart services), with
no automatic package autoremove. If the host signals reboot-required, it
must be handled as a **separate approved maintenance action**. Do not treat
a pending kernel update, a successful playbook run, or a Talk notice as
customer approval.

This public role is a reusable component, **not an operational deployment
authorization**. Production-specific inventories, approvers, backup policy,
next maintenance windows, and customer communications belong in the
private operational repository. See LibreCodeCoop/infrastructure-operations#64.
