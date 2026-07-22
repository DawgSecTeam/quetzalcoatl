# Pipeline Runbook

Operator runbook for the CyberDawgs automation suite: **what to run, on which machine, in
what order, with which arguments.** For what each script does internally, read the script
or the external wiki linked in `README.md`.

> ⚠️ Per `README.md`, the suite is untested since commit `32888256255156e30761ec6c5f0181993b59893e`.
> Use that revision for actual competitions. Most scripts assume **GNU** coreutils/grep.

## Overview

The suite has two halves:

- **Host-side push** — from the operator's machine, `minzero/deploy.sh` uses `sshpass` +
  GNU `parallel` to SSH into every target in parallel, transfer the toolkit, and run the
  first-touch hardening (firewall + accounts).
- **Target-side stages** — on each box (as root) you unpack the toolkit and run
  `activate.sh`, then the interactive `baseline/` scripts to hunt for the intruder.

```
 Stage 0 (clean box)      Stage 1-2 (operator host)          Stage 3-4 (each target, root)
 ┌────────────────┐       ┌────────────────────────┐         ┌──────────────────────────┐
 │ data-          │       │ hostfile + port-sources│  ssh    │ activate.sh              │
 │ collection.sh  │──┐    │        │               │ ──────► │  ├ backup.sh             │
 │ → baseline.    │  │    │        ▼               │ sshpass │  ├ auditd rules          │
 │   tar.gz       │  └───►│ minzero/deploy.sh      │ +parallel  ├ watchdawg (bg)        │
 └────────────────┘ (copy │  ├ autofirewall.sh     │         │  └ busybox / /bin/false  │
  clean snapshot into     │  └ harden.sh           │         │ baseline/standard.sh     │
  systems/<name>/)        └────────────────────────┘         │ baseline/specific.sh     │
                                                             └──────────────────────────┘
```

## Prerequisites

**On the operator host** (only place these are needed): `parallel`, `sshpass`.

**`minzero/hostfile`** — one line per target. The real format consumed by
`minzero/deploy.sh` is **5 space-separated fields**:

```
<system-name> <ip> <ssh-user> <old-password> <new-password-hash>
```

Example (`minzero/hostfile-test`):

```
web 10.0.0.239 admin Archer69 $6$3cc65cf8...
```

- `<system-name>` must match a directory under `systems/` (see below).
- Pregenerate `<new-password-hash>` with `funcs/passwordHasher.sh <password>`
  (openssl SHA-512 crypt). This hash becomes the `bluey` account password on the target.

**`systems/<system-name>/port-sources`** — one directory per target (name = field 1 of the
hostfile). `port-sources` has two lines of space-separated ports:

```
22 80 443     <- line 1: inbound ports to allow
53 80 443     <- line 2: outbound ports to allow
```

## Run order

### Stage 0 — Clean snapshot (on a clean/reference box, as root)

1. Install the scored services so the clean box mirrors the real target.
2. `baseline/data-collection.sh` → produces `/tmp/baseline.tar.gz` (packages, services,
   ports, SUID bits, `/etc` `/home` `/root`, etc).
3. Copy that `baseline.tar.gz` into each `systems/<name>/` so it ships to the matching
   target during deploy (see `systems/web/baseline.tar.gz`).

### Stage 1 — Operator prep (on the host machine, inside `minzero/`)

4. Create `hostfile` and each `systems/<name>/port-sources` as described in Prerequisites.

### Stage 2 — Deploy (on the host machine)

5. Run `minzero/deploy.sh` (no arguments — it reads `./hostfile`). For every host, in
   parallel, it:
   - Builds `resources.tar.gz` (activate.sh, c2scanner.sh, binaries, sshd_config, backup.sh,
     watchdawg + sources, auditd-rules, baseline/*).
   - `scp`s the resources + `harden.sh` + `autofirewall.sh` + that host's `port-sources`
     into `/tmp` on the target.
   - Runs **`autofirewall.sh`** (iptables lockdown driven by `port-sources`), then
     **`harden.sh`** (sets all shells to `/bin/false`, creates sudo user `bluey` with the
     hashed password, locks other system accounts), both over SSH via `SUDO_ASKPASS`.
   - Output is tee'd to `minzero/deploy.log`.

### Stage 3 — Activate (on each target, as root)

6. Unpack the toolkit and run activate:
   ```sh
   cd /tmp && tar -xzpf resources.tar.gz && ./activate.sh
   ```
   `activate.sh` runs `backup.sh` (snapshot → `/var/bk`, archive → `~/bk.tar.gz`), installs
   and loads the `auditd-rules`, launches **watchdawg** in the background as
   `/etc/kernel/watchdawg` (file-integrity monitor over `watchdawg-sources`), installs
   busybox, and replaces `/bin/false`.
   - Optional env-gated extras: set `DEPLOY_SPLUNK=yes` or `DEPLOY_TIMESYNCING=yes` before
     running (both are stubs today).

### Stage 4 — Baseline / hunt (on each target, as root)

7. `baseline/standard.sh` — interactive, distro-agnostic hardening walkthrough; ends by
   backgrounding `binaries/linpeas.sh` (offers lynis too). Output lands in `/tmp/linpeas`,
   `/tmp/lynis`.
8. `baseline/specific.sh` — runs `data-collection.sh` on this (dirty) box, then `diff -y`s
   it against the clean Stage 0 snapshot so you can spot attacker changes to services,
   packages, ports, PAM, sudoers, and `/etc`.

## Standalone tools (run ad hoc — not part of the main flow)

- `c2scanner.sh` — polls `ss` and prints new outbound connections.
- `angryc2scanner.sh` — same, but **kills** offending process trees (root only).
- `beaconfinder.sh` — waits for an established connection to a specific suspicious IP.
- `auditkey-notifier.sh` — tails the auditd event socket and posts alerts to a Discord
  webhook (fill in the `webhook` variable first).
- `deploy/ptp.sh`, `deploy/splunkforwarder.sh` — extra deploys, wired to the
  `DEPLOY_TIMESYNCING` / `DEPLOY_SPLUNK` toggles in `activate.sh`.

## Gotchas

- **Stale hostfile docs:** `minzero/README.md` shows a 3-field hostfile — that is outdated.
  The real format is the **5-field** one above (see `minzero/deploy.sh` `cut -f1..5`).
- **GNU assumptions:** several scripts use GNU-only flags (`grep -P`, `cp --parents`,
  `diff -y`); on Alpine/busybox install the GNU equivalents first.
- **Untested revision warning:** see the note at the top of this file and in `README.md`.
