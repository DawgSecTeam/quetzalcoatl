#!/bin/sh
# Script to capture snapshot of initial compitition state
# Maybe later compare binary sizes

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    printf "This script requires root privileges."
    exit 1
fi

# Create backup dirs
BACKUP_DIR=/var/tmp/snapshot

mkdir -p $BACKUP_DIR/filesystem/etc
mkdir -p $BACKUP_DIR/filesystem/root
mkdir -p $BACKUP_DIR/filesystem/home

## Service configurations and user data
cp -pr /etc/*  $BACKUP_DIR/filesystem/etc/
cp -pr /root/* $BACKUP_DIR/filesystem/root
cp -pr /home/* $BACKUP_DIR/filesystem/home/

## Kernel modules
lsmod > $BACKUP_DIR/kernelModules

## System services, active and startup
if [ -d /run/systemd/system ]; then
   # Systemd stuff
   systemctl list-units      --type=service --state=running --no-pager > $BACKUP_DIR/servicesActiveRunning
   systemctl list-unit-files --type=service --state=enabled --no-pager > $BACKUP_DIR/servicesEnabledAutostart
   systemctl list-units                               --all --no-pager > $BACKUP_DIR/servicesAllUnits
else
    # Openrc stuff
    rc-status --started --manual > $BACKUP_DIR/servicesActiveRunning
    rc-update -v show            > $BACKUP_DIR/servicesEnabledAutostart
    rc-update show               > $BACKUP_DIR/servicesAllUnits
fi

## Packages
# Alpine
if [ -x "$(command -v apk)" ];
then
    apk info > $BACKUP_DIR/packages
# Debian
elif [ -x "$(command -v dpkg)" ];
then
    dpkg -l > $BACKUP_DIR/packages
# RHEL
elif [ -x "$(command -v rpm)" ];
then
    rpm -qa > $BACKUP_DIR/packages
else
    printf "==> Unknown package manager, skipping\n"
fi

## Ports and firewall
ss -tulpn   > $BACKUP_DIR/openPorts
iptables -L > $BACKUP_DIR/iptablesRules

## Environmental variable
env > $BACKUP_DIR/environmentalVariables

## SUID bits
find / -perm -u=s -type f 2>/dev/null > $BACKUP_DIR/suidbits

## Pack files
printf "==> Archiving directory...\n"
tar -cpzf /var/tmp/baseline.tar.gz $BACKUP_DIR
printf "==> Done.\n"
