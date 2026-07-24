# Automated Full-Deploy Test

Runbook for an agent verifying the deploy pipeline end-to-end against live VMs. Pairs with
`README.md`, `minzero/README.md`, `systems/README.md`, `baseline/README.md`.

**Never hardcode hosts/IPs/credentials/ports/VM IDs in this file or a report.** Read them from
`minzero/hostfile` and `systems/<name>/port-sources` at runtime. Missing either for a host?
Stop and ask the operator — don't guess firewall rules or credentials.

## Steps

1. **Pre-flight**: `hostfile` + each host's `port-sources` exist; `parallel`/`sshpass`
  installed; all hosts ping.
2. **Deploy**: `minzero/deploy.sh`. Watch `minzero/deploy.log` for `--- All done ---` /
  `--- Failed ---` per host. Not safe to blindly re-run against an already-hardened host
  (see Lockout below).
3. **Verify** — one subagent per host, in parallel, read-only SSH, checking:
  - hostfile's original login is now dead; `bluey` works instead
  - escalation works (`sudo` or `doas`, whichever exists — `doas` needs a pty + password on
    stdin, no askpass equivalent)
  - `iptables -L -n` matches that host's `port-sources`; any `ufw`/`firewalld` present is
    stopped/disabled/masked
  - exactly one `watchdawg` process
  - `/opt/busybox/busybox` present, `/bin/false` resolves to it
  - auditd active (some rule-load failures are expected — see below)
  - `/var/tmp/.log/{activate,harden,autofirewall}.log` have no errors beyond "Known noise"
4. **Report** per host: pass/fail on each check above + any new error text.

## Known noise — don't re-report

- auditd: `auditd-rules` is RHEL-shaped, so a handful of rules always fail to load on other
 distros (missing `ntp`/`chrony` users, missing `/lib64` paths). auditd itself still comes up.

## Lockout

A host losing its original login after a successful deploy is the *intended* outcome, not a
bug — confirm `bluey` instead. A host unreachable via **both** accounts is a real bug with no
SSH recovery path; check `testing/` for out-of-band recovery, but any VM IDs found there may
not match the current `hostfile` — confirm the right target with the operator before touching
anything, since a rollback is destructive and irreversible.
