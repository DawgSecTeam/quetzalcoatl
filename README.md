# DawgSec Automation Suite
Courtesy of Dipa and Hamza

## Documentation
For information on what the scripts do/how they work/when to use them, read the code or ask an LLM.
More deploy documentation in the `baseline`, `minzero`, and `systems` directory READMEs.
Basic implementation guide in PIPELINE.md (will be moved here).

## Official policy: changes and competitions
**Changes:** When making changes, make them on a new branch. To merge the changes, they first all need to be tested. Commits on an unmerged branch are allowed to break functionality, as long as everything is fixed by the time a PR is made.

**Competitions:** When adding anything to the systems/ directory for a specific competition, clone the repository, so nothing in the main repo is modified. Everything in that directory is currently .gitignored, as is minzero/hostfile, so you will need to modify the gitignore

## Before we Merge
For this specific reworking of the scripts, we have some major changes to finish:

**backup**
- Backup will add restore and snapshot functionalities
- merge data-collection and backup scripts
   - either into one file with path choices or just have backup use data-collection
**logs**
- all scripts should create log files in a shared log directory, be run with tee from deploy: /var/tmp/.log/


- we're going to merge harden and activate, then have autofirewall be deployed by activate. meeting to discuss this web 22
- deploy currently relies on remotes having sudo, fix this
- make sure pass_* is deleted on the remote after deploy


Currenty broken: both baselines, backup



AI found issues:
**angryc2scanner**
- the parent-chain kill loop (line 37) has no guard for an empty `$ppid`. If `ps` returns nothing (process already dead, or PID doesn't exist) then `prev=""` and the loop spins forever running `kill -9 ""`. Needs `[ -n "$ppid" ]` in the while condition and a `[ -z "$ppid" ] && break` inside
- `awk '$1 { print $3 }'` uses field 1 as a truthiness test, so a numeric UID of `0` (which `ps -f` prints when the username is too long) is treated as false and prints nothing, hitting the same empty-`$ppid` path. Use `awk 'NR==1 { print $3 }'`

**baseline paths**
- `specific.sh:34-35` still uses `realpath ../sys-clean`, which resolves against the cwd instead of /var/tmp. Since data-collection tars an absolute path, the real roots after extraction are `/var/tmp/sys-{clean,dirty}/var/tmp/snapshot`
- `specific.sh` never creates /var/tmp/sys-clean and /var/tmp/sys-dirty, so the `tar -C` calls fail outright on a fresh box. Needs an `rm -rf` + `mkdir -p` before extracting
- backup.sh is still on the old paths: `/var/bk` (line 11) and `~/bk.tar.gz` (line 77). Should move to /var/tmp with the rest
- backup.sh's output filenames (`kernelmodules.txt`, `listeningports.txt`, `packages-debian.txt`) don't match what specific.sh diffs (`kernelModules`, `openPorts`, `packages`), so its tarball can't serve as a clean baseline. Resolved if we do the backup/data-collection merge above
- note: the `filesystem/` prefix in the diff commands is correct now that both sides come from data-collection. Don't strip it

**watchdawg**
- `watchdawg.sh:40` appends into `$INPUT` while the enclosing loop is still reading it (`:52 done < "$INPUT"`). Terminates on a normal tree but spins forever on a symlink cycle, and it permanently rewrites the deployed `/etc/kernel/sources` so every restart re-expands a longer list. An empty directory also appends a literal `path/*` entry. Expand into a separate watchlist file under `$BACKUP_DIR` and leave the sources file alone — `find "$line" -type f` replaces the manual recursion
- `watchdawg-sources:12-13` duplicate `/etc/pam.d` and `/etc/ssh` from lines 7-8

**auditkey-notifier**
- `$webhook` is never assigned, so every alert curls an empty URL (`auditkey-notifier.sh:26,40`). The comment at `:9` documents the gap but nothing reads an env var. Needs `webhook="${WEBHOOK_URL:?set WEBHOOK_URL}"` up top, or reuse `funcs/discordNotif.sh`
- `UID=$(...)` at `:21,35` is a readonly assignment under bash. On the Fedora/Rocky targets, where `/bin/sh` is bash, it errors and the alert reports the auditing process's own uid instead of the offender's. Rename to `AUID`. Confirmed: `bash -c 'UID=5'` → `UID: readonly variable`
- `:29-30` are two sibling `case` blocks, so a line carrying both `recon` and `susp_activity` fires two notifications. Merge into one `*"$ALERT_KEY1"*|*"$ALERT_KEY2"*)` arm
- `$JSON` is built at `:22,36` and never used — either send it as the curl payload or drop it

**auditd rules**
- `auditd-rules:312-313` have `-k -F T1078_Valid_Accounts`. `auditctl` reads `-F` as the key and chokes on the trailing token, so both setfiles rules fail to load. Should be `-k T1078_Valid_Accounts`, matching `:317-318`
- 15 `-w` rules carry no `-p` (`:104-106,184-185,384,396-399,401-405`). Not a blind spot — an unqualified watch defaults to `rwxa` — but it means we're auditing reads on /etc/shadow and every docker binary. Adding `-p wa` would cut volume with no detection loss. Low priority

**backup**
- `backup()` is defined at `backup.sh:27-78` but never called. The script writes `sources.txt`, prints the menu at `:82`, and exits — so `activate.sh:17` takes no backup at all. This is the "backup is broken" note above; the selection logic in the `:83-84` TODOs is what's missing. Whatever we land needs a non-interactive path, since deploy runs it over `ssh ... < /dev/null`
- `backup.sh:31` — `cp -pr "${src}/*" "$dest/"` quotes the glob so it never expands. Copies would fail even once `backup()` is wired up. Use `"${src}/."`
- `$BACKUP_DIR` is unquoted in 16 places (`:13,35,36,40-42,45-47,54,58,62,68-70,73,77`)
- `pstree`, `nft`, `iptables`, and `rc-status` are called unconditionally (`:36,45-47,69,70`) while the package managers get `command -v` guards at `:52-62`. Missing tools write empty files and dump errors into the log

**c2scanner / angryc2scanner**
- `c2scanner.sh:7` and `angryc2scanner.sh:13` seed `FNAME_LAST` to `"$(date +%s)ProMax"`, a file that never exists, so the first `diff` errors to stderr. Harmless (exit 2 → empty `$DIFF` → no false alert) but it should take a real first snapshot before entering the loop
- neither prunes `scans/`, which grows by two files per second for as long as the scanner runs

**beaconfinder**
- `beaconfinder.sh:12` — `printf "$A\n"` passes `ss` output as the format string, so a `%` in a process name corrupts or truncates the alert. `printf '%s\n' "$A"`

**activate**
- `activate.sh:64` — `mkdir /opt/busybox` has no `-p`, so a second run errors
- `:67` re-appends the busybox PATH line to /etc/profile on every run, and `printf` without a trailing `\n` glues it onto whatever appends next. Guard with `grep -q`
- `:17` tees into `/var/tmp/.log/` without creating it. Only works because `minzero/deploy.sh:54` mkdirs it first — standalone runs of activate.sh fail
- `:63,65` assume `/var/tmp/binaries/busybox` exists. Fine via deploy (it ships in resources.tar.gz), but standalone runs should skip the section with a warning rather than error
