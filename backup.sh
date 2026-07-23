#!/bin/sh
# Script to capture snapshot of initial compitition state

# bash is trash and shell is hell
# i code under their cursed spell
# sometimes i feel a spark of hope
# of the variety called "cope"

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root."
    exit 1
fi

# This will be set further down
SNAPSHOT="default"

# Make files created here private
umask 077

# Create backup directory
BACKUP_DIR=/var/tmp/bk

mkdir -p $BACKUP_DIR
chmod 700 $BACKUP_DIR

cat > "$BACKUP_DIR/sources.txt" << 'EOF'
/etc
/home
/root
/config
/conf
/var/www
/var/log
/var/spool
/usr/lib/systemd/system
/lib/systemd/system
EOF

# Prevents overwriting snapshots
snapshot_bail_if_exists() {
    if [ -e "$BACKUP_DIR/$SNAPSHOT" ]; then
        printf "[ERROR] Snapshot '%s' already exists. Pick another name, or delete it first.\n" "$SNAPSHOT" >&2
        exit 1
    fi
}

# Make sure space is present to take backup
check_space() {
    need=0
    while IFS= read -r src; do
        [ -d "$src" ] || continue
        sz=$(du -sk "$src" 2>/dev/null | cut -f1)
        [ -n "$sz" ] || sz=0
        need=$((need + sz))
    done < "$BACKUP_DIR/sources.txt"
    need=$((need * 2))

    free=$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 { print $4 }')
    [ -n "$free" ] || return 0

    if [ "$need" -gt "$free" ]; then
        printf "== WARNING: snapshot needs about %s MB, only %s MB free on %s ==\n" \
            "$(((need + 1023) / 1024))" "$(((free + 1023) / 1024))" "$BACKUP_DIR"
    fi
}

# Create initial filesystem backup
backup() {
    printf "========================\nRUNNING BACKUP\n========================\n"

    check_space

    while IFS= read -r src; do
        [ -d "$src" ] || continue
        dest="$BACKUP_DIR/$SNAPSHOT/filesystem${src}"
        mkdir -p "$dest"
        cp -a "${src}/." "$dest/"
    done < "$BACKUP_DIR/sources.txt"

    ## Processes and services
    ps aux    > $BACKUP_DIR/$SNAPSHOT/processes-ps_aux.txt
    pstree -p > $BACKUP_DIR/$SNAPSHOT/processes-pstree.txt

    if [ -d /run/systemd/system ]; then
        # Systemd stuff
        systemctl list-units      --type=service --state=running --no-pager > $BACKUP_DIR/$SNAPSHOT/services-active_running.txt
        systemctl list-unit-files --type=service --state=enabled --no-pager > $BACKUP_DIR/$SNAPSHOT/services-enabled_autostart.txt
        systemctl list-units                               --all --no-pager > $BACKUP_DIR/$SNAPSHOT/services-all_units.txt
    else
        # Openrc stuff
        rc-status --started --manual > $BACKUP_DIR/$SNAPSHOT/services-active_running.txt
        rc-update -v show            > $BACKUP_DIR/$SNAPSHOT/services-enabled_autostart.txt
        rc-update show               > $BACKUP_DIR/$SNAPSHOT/services-all_units.txt
    fi

    ## Packages
    # Alpine
    if [ -x "$(command -v apk)" ];
    then
        apk info > $BACKUP_DIR/$SNAPSHOT/packages.txt
    # Debian
    elif [ -x "$(command -v apt)" ];
    then
        dpkg -l > $BACKUP_DIR/$SNAPSHOT/packages.txt
    # RHEL
    elif [ -x "$(command -v dnf)" ];
    then
        rpm -qa > $BACKUP_DIR/$SNAPSHOT/packages.txt
    else
        printf "== Unknown package manager ==\n"
    fi

    ## Ports and firewall
    ss -tulpn      > $BACKUP_DIR/$SNAPSHOT/listeningports.txt
    # read iptable rules with iptables-save to avoid network calls
    if [ -x "$(command -v iptables-save)" ];
    then
        iptables-save > $BACKUP_DIR/$SNAPSHOT/iptablesrules.txt
    else
        iptables -n -L > $BACKUP_DIR/$SNAPSHOT/iptablesrules.txt
    fi
    nft list ruleset > $BACKUP_DIR/$SNAPSHOT/nftablesrules.txt

    ## Kernel modules
    lsmod > $BACKUP_DIR/$SNAPSHOT/kernelmodules.txt

    # Extended fields, only needed for baseline clean/dirty comparisons
    if [ "$EXTENDED" = "1" ]; then
        find / -xdev -perm -u=s -type f 2>/dev/null > "$BACKUP_DIR/$SNAPSHOT/suidbits.txt"
        env > "$BACKUP_DIR/$SNAPSHOT/environmentalvariables.txt"
    fi

    # Date snapshot was completed
    date > "$BACKUP_DIR/$SNAPSHOT/date_taken"

    # Compress backup
    printf "== Archiving directory... ==\n"
    mkdir -p "$BACKUP_DIR/archives"
    tar -cpzf "$BACKUP_DIR/archives/$SNAPSHOT.tar.gz" -C "$BACKUP_DIR" "$SNAPSHOT"
    chmod 600 "$BACKUP_DIR/archives/$SNAPSHOT.tar.gz"

    printf "============\nBACKUP COMPLETED\n============\n"
}

restore() {
    printf "========================\nRUNNING RESTORE\n========================\n"
    if [ -d "$BACKUP_DIR/$SNAPSHOT/filesystem" ]; then
        printf "Please note that restore only applies to files\n"

        extras="$BACKUP_DIR/$SNAPSHOT/restore-extras.txt"
        : > "$extras"

        while IFS= read -r src; do
            dest="$BACKUP_DIR/$SNAPSHOT/filesystem${src}"
            [ -d "$dest" ] || continue

            # Record files added since last backup
            if [ -d "$src" ]; then
                find "$dest" | sed "s|^$dest||" | sort > "$BACKUP_DIR/.snapshot.list"
                find "$src"  | sed "s|^$src||"  | sort > "$BACKUP_DIR/.live.list"
                comm -13 "$BACKUP_DIR/.snapshot.list" "$BACKUP_DIR/.live.list" \
                    | sed "s|^|$src|" >> "$extras"
            fi

            cp -a "$dest/." "${src}/"

            # SELinux relabling
            if [ -x "$(command -v restorecon)" ]; then
                restorecon -R "$src" > /dev/null 2>&1
            fi
        done < "$BACKUP_DIR/sources.txt"

        rm -f "$BACKUP_DIR/.snapshot.list" "$BACKUP_DIR/.live.list"

        if [ -s "$extras" ]; then
            printf "== Present now but NOT in the snapshot, and NOT removed: ==\n"
            cat "$extras"
            printf "== Saved to %s ==\n" "$extras"
        fi

        printf "============\nRESTORE COMPLETED\n============\n"
    else
        printf "============\nINVALID SNAPSHOT, RESTORE FAILED\n============\n"
    fi
}


# script is being run automatically
if [ "$1" = "backup" ]; then
    bk_name="$2"

    SNAPSHOT=${bk_name:-"auto-$(date +%Y%m%d-%H%M%S)"}
    snapshot_bail_if_exists
    backup 2>&1 | tee -a /var/tmp/.log/backup.log
elif [ "$1" = "restore" ]; then
    if [ $# -eq 1 ]; then
        printf "No restore name given, exiting.\n"
    else
        SNAPSHOT=$2
        restore 2>&1 | tee -a /var/tmp/.log/backup.log
    fi
elif [ "$1" = "baseline" ]; then
    SNAPSHOT="baseline"
    EXTENDED=1
    rm -rf "$BACKUP_DIR/$SNAPSHOT"
    backup 2>&1 | tee -a /var/tmp/.log/backup.log
    cp "$BACKUP_DIR/archives/$SNAPSHOT.tar.gz" /var/tmp/baseline.tar.gz
# script was run manually
else
    printf "Welcome to the backup toolkit, choose an option:\n [1] Create new backup \n [2] Restore backup \n [3] Exit\n" >&2
    read -r option
    if [ "$option" = "1" ]; then
        printf "Name the backup:\n"
        read -r bk_name
        SNAPSHOT=$bk_name
        snapshot_bail_if_exists
        backup 2>&1 | tee -a /var/tmp/.log/backup.log
    elif [ "$option" = "2" ]; then
        printf "Choose a backup to restore from:\n"
        for save in $BACKUP_DIR/*; do
            [ -d "$save" ] || continue
            save_name=$(basename "$save")
            [ "$save_name" = "archives" ] && continue
            if [ -f "$save/date_taken" ]; then
                save_date=$(cat "$save/date_taken")
            else
                save_date="unknown date"
            fi
            printf "> %s saved on %s\n" "$save_name" "$save_date"
        done
        printf "restore from: "
        read -r snapshot_to_restore_from
        SNAPSHOT=$snapshot_to_restore_from
        restore 2>&1 | tee -a /var/tmp/.log/backup.log
    else
        printf "Exiting\n"
    fi
fi
