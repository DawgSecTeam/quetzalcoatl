#!/bin/sh
# Script to capture snapshot of initial compitition state

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root or with sudo."
    exit 1
fi

# Create backup directory
BACKUP_DIR=/var/bk

mkdir -p $BACKUP_DIR

cat > "$BACKUP_DIR/sources.txt" << 'EOF'
/etc
/home
/root
/config
/conf
/var/www
/var/log
/var/spool
EOF

# Create initial filesystem backup
backup() {
    while IFS= read -r src; do
    dest="$BACKUP_DIR/filesystem${src}"
    mkdir -p "$dest"
    cp -pr "${src}/*" "$dest/"
    done < "$BACKUP_DIR/sources.txt"

    ## Processes and services
    ps aux    > $BACKUP_DIR/processes-ps_aux.txt
    pstree -p > $BACKUP_DIR/processes-pstree.txt

    if [ -d /run/systemd/system ]; then
        # Systemd stuff
        systemctl list-units      --type=service --state=running --no-pager > $BACKUP_DIR/services-active_running.txt
        systemctl list-unit-files --type=service --state=enabled --no-pager > $BACKUP_DIR/services-enabled_autostart.txt
        systemctl list-units                               --all --no-pager > $BACKUP_DIR/services-all_units.txt
    else
        # Openrc stuff
        rc-status --started --manual > $BACKUP_DIR/services-active_running.txt
        rc-update -v show            > $BACKUP_DIR/services-enabled_autostart.txt
        rc-update show               > $BACKUP_DIR/services-all_units.txt
    fi

    ## Packages
    # Alpine
    if [ -x "$(command -v apk)" ];
    then
        apk info > $BACKUP_DIR/packages-alpine.txt
    # Debian
    elif [ -x "$(command -v apt)" ];
    then
        dpkg -l > $BACKUP_DIR/packages-debian.txt
    # RHEL
    elif [ -x "$(command -v dnf)" ];
    then
        rpm -qa > $BACKUP_DIR/packages-rhel.txt
    else
        printf "== Unknown package manager ==\n"
    fi

    ## Ports and firewall
    ss -tulpn      > $BACKUP_DIR/listeningports.txt
    iptables -L > $BACKUP_DIR/iptablesrules.txt
    nft list ruleset > $BACKUP_DIR/nftablesrules.txt

    ## Kernel modules
    lsmod > $BACKUP_DIR/kernelmodules.txt

    # Compress backup to home
    printf "== Archiving directory... ==\n"
    tar -cpzf ~/bk.tar.gz $BACKUP_DIR
}


# Selection logic
printf "Welcome to the backup toolkit, choose an option:\n [1] Create new backup \n [2] Restore backup \n [3] Exit\n"
# should handle each one, update backup to rely on a name variable
# either have it create an automatic backup when first run, or allow passing a flag to create a named backup, and use it in activate


# for activate, integrate much of the functionality into deploy's automatic run


# all scripts should create log files in a shared log directory, be run with tee from deploy