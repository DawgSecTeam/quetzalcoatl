# Dependencies
Only for the host system
parallel, sshpass

# Order of operations
* YOU NEED TO CREATE A `hostfile` FILE in this directory
    * must be in this format: `<system-name> <ip> <ssh-user> <current-password> <new-password-hash>`
    * one line per host
    * `<system-name>` must match a directory in `../systems/`, which gets uploaded along with its `port-sources`
    * pregenerate all password hashes with `../funcs/passwordHasher.sh`
* execute `deploy.sh`
    * tars up all resources and scps everything to /var/tmp
    * creates /var/tmp/.log for remote logs
    * runs autofirewall.sh (sets iptable rules)
    * runs harden.sh (sets /bin/false shells, adds bluey, sets bluey password, locks system accounts)
    * runs activate.sh, which
        * runs backup.sh
        * installs auditd and applies the rules
        * deploys watchdawg to /etc/kernel
        * deploys busybox to /opt/busybox and replaces /bin/false
* deploy logs are saved to `deploy.log` on the host
* after deploy, run the baseline scripts (`standard.sh`, `specific.sh`) on the target
