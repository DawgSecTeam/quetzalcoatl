#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  printf "This script requires root privileges. Exiting\n"
  exit 1
fi

printf "Starting activation script...\n"

cd /var/tmp

############################
# Machine readable result
############################
# deploy.sh must never print "All done" for a box that is not actually hardened.
# activate.sh records what happened here; the file stays world readable because
# /var/tmp/.log is created 0777 by the deploy user.
STATUS_FILE=/var/tmp/.log/activate.status
FAIL_REASON=""
finish() {
   if [ -z "$FAIL_REASON" ]; then
      printf 'ok\n' > "$STATUS_FILE"
   else
      printf 'FAIL: %s\n' "$FAIL_REASON" > "$STATUS_FILE"
   fi
}
die() {
   printf "FATAL(%s): %s\n" "$1" "$2"
   FAIL_REASON="$1 $2"
   finish
   exit "$1"
}

############################
# Creating directories
############################

# Logging
mkdir -p /var/tmp/.log
chmod 777 /var/tmp/.log
printf 'pending\n' > "$STATUS_FILE"

############################
# Install critical software
############################

if ! command -v iptables > /dev/null; then
   printf "iptables missing, installing...\n"

   if command -v apt > /dev/null; then
      apt-get update -qq || true
      apt-get install -y iptables
   fi

   if command -v apk > /dev/null; then
      apk add -q iptables
      rc-update add iptables
      rc-service iptables save
   fi

   # RHEL/Fedora shipped iptables as a replacement for firewalld for a reason:
   # without it there is no firewall at all on these images.
   if command -v dnf > /dev/null; then
      dnf install -y iptables iptables-services
   elif command -v yum > /dev/null; then
      yum install -y iptables iptables-services
   elif command -v pacman > /dev/null; then
      pacman -Sy --noconfirm iptables
   elif command -v zypper > /dev/null; then
      zypper --non-interactive install iptables
   fi

   if ! command -v iptables > /dev/null; then
      die 10 "iptables could not be installed - no firewall can be applied"
   fi
fi

############################
# setting up lax firewall
############################
printf "Starting autofirewall.sh with package manager\n"
/var/tmp/autofirewall.sh -d 2>&1 | tee /var/tmp/.log/autofirewall.log
printf "Finished autofirewall.sh with package manager\n"

############################
# Taking initial backup
############################
printf "==> Deploying backup\n"
printf "IMPORTANT NOTE -- OUTPUT OF ps, ss, AND cp WILL BE DIFFERENT AFTER BUSYBOX IS CONFIGURED\n"
chmod +x backup.sh
./backup.sh backup initial

############################
# Setting up auditd
############################
printf "==> Deploying auditd\n"
printf "====> Installing auditd\n"
if command -v auditctl > /dev/null 2>&1; then
   printf "Already installed\n"
else
   if command -v dnf > /dev/null; then
      dnf install -y audit
   elif command -v apt > /dev/null; then
      apt-get install -y auditd
   elif command -v apk > /dev/null; then
      apk add audit
   elif command -v yum > /dev/null; then
      yum install -y audit
   fi
fi

# apt/dnf can fail (interrupted dpkg state, missing repo, blocked network while
# the firewall is up). Never continue as if auditing exists.
if ! command -v auditctl > /dev/null 2>&1; then
   die 11 "auditd is not installed - nothing would be audited"
fi

printf "====> Applying rules\n"
mkdir -p /etc/audit/rules.d
cp auditd-rules /etc/audit/rules.d/standard.rules
chmod 0600 /etc/audit/rules.d/standard.rules

printf "====> Starting service\n"
if command -v rc-service > /dev/null 2>&1; then
    rc-update add auditd default
    rc-service auditd restart
else
    service auditd restart 2>/dev/null || true
fi

# OpenRC's auditd init loads RULEFILE_STARTUP=/etc/audit/audit.rules, NOT
# rules.d/, so the old "rc-service elif augenrules" chain left Alpine running
# with zero rules. Build and load the rules on every OS.
printf "====> Loading rules\n"
if command -v augenrules > /dev/null 2>&1; then
    augenrules --load
else
    cat /etc/audit/rules.d/*.rules > /etc/audit/audit.rules
    auditctl -R /etc/audit/audit.rules
fi

# Immutable only after loading, otherwise every later rule update is a silent
# "Operation not permitted".
chattr +i /etc/audit/rules.d/standard.rules

loaded=$(auditctl -l 2>/dev/null | grep -c -e '^-a' -e '^-w')
printf "====> auditctl reports %s rules loaded\n" "$loaded"
if [ "$loaded" -eq 0 ]; then
   die 12 "auditd is running with 0 rules - no auditing is happening"
fi

############################
# Deploying watchdawg
############################
printf "==> Deploying watchdawg\n"
chmod 700 watchdawg.sh
mkdir -p /etc/kernel
mv /var/tmp/watchdawg.sh /etc/kernel/watchdawg
mv /var/tmp/watchdawg-sources /etc/kernel/sources
nohup /etc/kernel/watchdawg /etc/kernel/init-state /etc/kernel/sources > /etc/kernel/out 2>&1 &

############################
# Setting up busybox
############################
printf "==> Deploying busybox\n"
#curl -k -L -O https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x /var/tmp/binaries/busybox
mkdir -p /opt/busybox
cp -p /var/tmp/binaries/busybox /opt/busybox/
/opt/busybox/busybox --install -s /opt/busybox
# Drop-in instead of appending to /etc/profile: idempotent and it cannot corrupt
# the previous line (printf without a trailing newline used to merge the two
# exports into 'export PATH=/opt/busybox:$PATHexport ...').
# Busybox is appended, not prepended: shadowing GNU grep/find/diff breaks the
# baseline scripts (grep -P, find -ls, diff -y) on glibc systems.
mkdir -p /etc/profile.d
printf 'export PATH="$PATH:/opt/busybox"\n' > /etc/profile.d/zz-busybox.sh
chmod 644 /etc/profile.d/zz-busybox.sh
export PATH="$PATH:/opt/busybox"
printf "==> Replacing /bin/false\n"
ln -sf /opt/busybox/false /bin/false

printf "[DONE] Log out if using ssh and log back in to activate busybox\n"


############################
# Running autofirewall.sh
############################

printf "Starting autofirewall.sh\n"
# "cmd | tee log" hides the exit status of cmd (tee always wins): that is how a
# box with no iptables at all reported a finished firewall.
/var/tmp/autofirewall.sh > /var/tmp/.log/autofirewall.log 2>&1
rc=$?
tail -n 3 /var/tmp/.log/autofirewall.log
if [ "$rc" -ne 0 ]; then
   die 13 "autofirewall.sh failed with rc=$rc - firewall state is unknown"
fi
printf "Finished autofirewall.sh\n"

############################
# Running harden.sh
############################

printf "Starting harden.sh\n"
/var/tmp/harden.sh "$1" > /var/tmp/.log/harden.log 2>&1
rc=$?
tail -n 3 /var/tmp/.log/harden.log
if [ "$rc" -ne 0 ]; then
   die 14 "harden.sh failed with rc=$rc - accounts are not hardened, see /var/tmp/.log/harden.log"
fi
printf "Finished harden.sh\n"

printf "Finished activation script\n"
printf "Check out the baselining scripts standard.sh and specific.sh\n"
finish
