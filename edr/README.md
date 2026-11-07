# EDR module — Falco + Wazuh log forwarding

Deployed by `activate.sh` (part of `minzero/deploy.sh`), or standalone on a box
that already has root access.

## What it does

1. **Falco** — installs the host runtime-detection sensor (modern eBPF driver,
   kmod fallback for old kernels), installs the competition rule set
   (`falco/ccdc-competition.yaml`), writes a minimal `falco.yaml` (JSON alerts to
   `/var/log/falco/events.json`), masks `falcoctl-artifact-follow` so nothing
   tries to pull rules from the internet mid-round, and starts the service.
2. **Wazuh agent** — installs the agent pointed at the manager (default
   `10.0.0.218`), configures file-integrity monitoring on the paths red touches
   (`/etc`, `/bin`, `/usr/bin`, cron/systemd units, `/root/.ssh`, docroots),
   and ships `auth.log`/`syslog`/`audit.log`/Falco JSON to the manager.
   Active response is disabled (alert-only).
3. **Syslog fallback** — on Alpine (or when the agent package is missing) ships
   syslog to the manager's `514/udp` input instead.
4. **Tamper watchdog** — `edr-watchdog.timer` restarts Falco/Wazuh if red kills
   them.

Everything is idempotent and fail-soft: a broken EDR deploy logs to
`/var/tmp/.log/edr.log`, leaves `activate.sh` running, and never touches a
scored service.

## Offline staging (do this before the round)

The deploy is **offline-first**: it uses packages in `edr/pkg/` and does not
touch the network unless `EDR_ALLOW_NETWORK=1`.

```bash
./edr/stage-pkgs.sh all        # on a connected box; fills edr/pkg/
```

`edr/pkg/` is gitignored. The deploy bundle (`resources.tar.gz`) includes it
when present, so one `minzero/deploy.sh` run ships the packages to every host.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `EDR_WAZUH_MANAGER` | `10.0.0.218` | Wazuh manager address |
| `EDR_PKG_DIR` | `edr/pkg` | offline package directory |
| `EDR_ALLOW_NETWORK` | `0` | `1` = fall back to vendor repos when no local package |
| `EDR_SKIP_FALCO` | `0` | `1` = skip Falco |
| `EDR_SKIP_WAZUH` | `0` | `1` = skip Wazuh forwarder |

In `activate.sh`, set `EDR_SKIP=1` to disable the whole module for one run.

## Standalone use

```bash
sudo EDR_WAZUH_MANAGER=10.0.0.218 EDR_ALLOW_NETWORK=1 ./edr/deploy-edr.sh
```

## Manager prerequisites (one-time, on 10.0.0.218)

Two things must exist on the Wazuh manager or the forwarders look healthy while
producing nothing visible:

1. **Falco decode rules** — without them every Falco JSON line is an unmatched log
   entry, not an alert:
   ```bash
   ./edr/wazuh/manager/install-manager.sh        # copies ccdc-falco.xml + restarts manager
   ```
   Adds rule 100700-100704 (`group: falco,ccdc`) — CCDC rule hits become level-12
   alerts with the Falco rule name in the description.
2. **Syslog input 514/udp** — required for the Alpine/no-agent path:
   ```xml
   <remote>
     <connection>syslog</connection>
     <port>514</port>
     <protocol>udp</protocol>
     <allowed-ips>10.0.0.0/8</allowed-ips>
   </remote>
   ```
   (`queue_size` is NOT valid on a syslog remote — remoted refuses to start.)

## Verify

```bash
systemctl is-active falco-modern-bpf wazuh-agent edr-watchdog.timer
falco --support | grep -c ccdc-competition     # rules file loaded at startup
tail -5 /var/log/falco/events.json            # alerts as JSON
/var/ossec/bin/wazuh-control info             # agent version/status
journalctl -u wazuh-agent -n 30               # enrollment errors live here
```

Manager side: agent should appear **Active** in the dashboard, and Falco alerts
land in `wazuh-alerts-*` with `rule.groups` containing `falco`.

## Supported distros

| Family | Falco | Wazuh agent |
|---|---|---|
| Debian/Ubuntu (deb) | yes | yes |
| RHEL/Rocky/Alma/Fedora (rpm) | yes | yes |
| Alpine | no musl build — syslog forwarding only | no apk package — syslog forwarding only |

Alpine boxes get syslog forwarding only; that is a deliberate limitation, not a
bug. The manager needs a syslog remote configured (`514/udp`) for that path.
