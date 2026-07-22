# DawgSec Automation Suite
Courtesy of Dipa and Hamza

## Documentation
For information on what the scripts do/how they work/when to use them, *read the code*.
More deploy documentation in the `baseline` and `minzero` directory READMEs.
Basic implementation guide in PIPELINE.md (will be moved here).

## To-do (move to Nextcloud deck)
- pipe baseline specific out to a file
- fix diff -y broken on alpine (install diffutils)
- Offline auditd installation
- Revise audit-rules file
- Dynamic auditd rule installtion script for watching binaries based on specific paths on different distros
- deploy runs backup and sends back to system executed from
- ensure busybox deploy actually works
- in-place deploy (try localhost on deploy)
- jumpstart script curled into shell that installs packages and pulls repo + runs deploy
- Toggle outgoing on and off for package installs in activate
- Investigate https://github.com/MZBCodes/NCAE-CyberGames/blob/main/Scripts/base_harden.sh
- Use inotifywait for watchdawg
- in standard baseline run linpeas as non-root
- Write fake shell to replace /bin/false (discord ping when used) or rbash
- Add per-box watchdawg rules

## Official policy, going forward:
When making changes, make them on a new branch. To merge the changes, they first all need to be tested. Commits on an unmerged branch are allowed to break functionality, as long as everything is fixed by the time a PR is made.
When adding anything to the systems/ directory for a specific competition, clone the repository, so nothing in the main repo is modified.






## Before we Merge
For this reworking of the scripts, we have some major changes:

- Backup will add restore and snapshot functionalities
- for activate, integrate much of the functionality into deploy's automatic run
- all scripts should create log files in a shared log directory, be run with tee from deploy
- /var/tmp/.log/
- merge data-collection and backup scripts
- either into one file with path choices or just have backup use data-collection
- we're going to merge harden and activate, then have autofirewall be deployed by activate. meeting to discuss this
- deploy current relies on remotes having sudo, fix this
- make sure pass_* is deleted on the remote after deploy