## Overview

The suite has two halves:

- **Host-side push** — from the operator's machine, `minzero/deploy.sh` uses `sshpass` +
  GNU `parallel` to SSH into every target in parallel, transfer the toolkit, and run the
  first-touch hardening (firewall + accounts) **and** the on-box activation, all remotely.
- **Target-side baseline** — once deploy finishes, you log into each box (as root) and run
  the interactive `baseline/` scripts to hunt for the intruder.

```
 Stage 0 (clean box)      Stage 1-2 (operator host)          Stage 3 (each target, root)
 ┌────────────────┐       ┌────────────────────────┐         ┌──────────────────────────┐
 │ data-          │       │ hostfile + port-sources│  ssh    │ baseline/standard.sh     │
 │ collection.sh  │──┐    │        │               │ ──────► │ baseline/specific.sh     │
 │ → baseline.    │  │    │        ▼               │ sshpass │                          │
 │   tar.gz       │  └───►│ minzero/deploy.sh      │ +parallel                          │
 └────────────────┘ (copy │  ├ autofirewall.sh     │         │                          │
  clean snapshot into     │  ├ harden.sh           │         │                          │
  systems/<name>/)        │  └ activate.sh         │         │                          │
                          └────────────────────────┘         └──────────────────────────┘
```

Everything the toolkit ships and runs lives under **`/var/tmp`** on the target. Deploy
output is saved locally to `minzero/deploy.log`; every remote step tees its own log into
`/var/tmp/.log/` on the box.

## Run order

### Stage 0 — Clean snapshot (on a clean/reference box, as root)

1. Install the scored services so the clean box mirrors the real target.
2. `baseline/data-collection.sh` → snapshots packages, services, ports, SUID bits, env,
   kernel modules, and `/etc` `/home` `/root` into `/var/tmp/snapshot`, then packs it to
   `/var/tmp/baseline.tar.gz`.
3. Copy that `baseline.tar.gz` into each `systems/<name>/` so it ships to the matching
   target during deploy (see `systems/debian/baseline.tar.gz`).

### Stage 1 — Operator prep (on the host machine, inside `minzero/`)

4. Create `hostfile` (one line per host:
   `<system-name> <ip> <ssh-user> <current-password> <new-password-hash>`) and a
   `systems/<name>/port-sources` for each host. `<system-name>` must match a directory in
   `../systems/`. Pregenerate the password hashes with `../funcs/passwordHasher.sh`.

### Stage 2 — Deploy (on the host machine)

5. Run `minzero/deploy.sh` (no arguments — it reads `./hostfile`). It first builds
   `resources.tar.gz` (activate.sh, harden.sh, autofirewall.sh, c2scanner.sh, binaries/,
   backup.sh, watchdawg.sh + watchdawg-sources, auditd-rules, baseline/*). Then for every
   host, in parallel, it:
   - Writes a per-host `pass_<name>` askpass helper holding the current password.
   - `scp`s `resources.tar.gz`, that host's `port-sources`, the whole `systems/<name>/`
     directory (carries the Stage 0 `baseline.tar.gz`), and `pass_<name>` into `/var/tmp`.
   - Creates `/var/tmp/.log` and unpacks `resources.tar.gz` in place.
   - Runs, each over SSH via `SUDO_ASKPASS=/var/tmp/pass_<name> sudo -A`:
     - **`autofirewall.sh`** — iptables lockdown driven by `port-sources`
       (→ `/var/tmp/.log/autofirewall.log`).
     - **`harden.sh`** — sets all shells to `/bin/false`, creates sudo user `bluey` with
       the hashed password, locks other system accounts, and `chattr +i`s
       passwd/shadow/group (→ `/var/tmp/.log/harden.log`).
     - **`activate.sh`** — backup + auditd + watchdawg + busybox (see Stage 3 detail below)
       (→ `/var/tmp/.log/activate.log`).
   - Deletes the remote `pass_<name>` file.
   - All host-side output is tee'd to `minzero/deploy.log`.

   `activate.sh` (run remotely by deploy) runs `backup.sh` (snapshot → `/var/bk`, archive →
   `~/bk.tar.gz`; its own log → `/var/tmp/.log/backup.log`), installs and loads the
   `auditd-rules`, launches **watchdawg** in the background as `/etc/kernel/watchdawg`
   (file-integrity monitor over `/etc/kernel/sources`), installs busybox to `/opt/busybox`,
   and replaces `/bin/false`. The Splunk / time-sync blocks are commented-out stubs today.

### Stage 3 — Baseline / hunt (on each target, as root)

6. `baseline/standard.sh` — interactive, distro-agnostic hardening walkthrough; offers
   lynis and ends by backgrounding `binaries/linpeas.sh`. Output lands in `/var/tmp/linpeas`
   and `/var/tmp/lynis`.
7. `baseline/specific.sh` — runs `data-collection.sh` on this (dirty) box, then `diff -y`s
   it against the clean Stage 0 snapshot so you can spot attacker changes to services,
   packages, ports, PAM, sudoers, and `/etc`.

## Standalone tools (run ad hoc — not part of the main flow)

- `c2scanner.sh` — polls `ss` and prints new outbound connections.
- `angryc2scanner.sh` — same, but **kills** offending process trees (root only).
- `beaconfinder.sh` — waits for an established connection to a specific suspicious IP.
- `auditkey-notifier.sh` — tails the auditd event socket and posts alerts to a Discord
  webhook (fill in the `webhook` variable first).
- `deploy/ptp.sh`, `deploy/splunkforwarder.sh` — extra deploys (time-sync / Splunk
  forwarder). Currently standalone stubs; the activate.sh hooks for them are commented out.
