#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  printf "This script requires root privileges. Exiting\n"
  exit 1
fi

printf "Starting activation script...\n"

cd /var/tmp

############################
# Creating directories
############################

# Logging
mkdir -p /var/tmp/.log
chmod 777 /var/tmp/.log

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
if command -v auditd > /dev/null; then
   printf "Already installed\n"
else
   if command -v dnf > /dev/null; then
      dnf install audit -y
   elif command -v apt > /dev/null; then
      apt install auditd -y
   elif command -v apk > /dev/null; then
      apk add audit
   fi
fi

printf "====> Applying rules\n"
cp auditd-rules /etc/audit/rules.d/standard.rules
chmod 0600 /etc/audit/rules.d/standard.rules
chattr +i /etc/audit/rules.d/standard.rules

printf "====> Restarting service\n"
if command -v augenrules >/dev/null 2>&1; then
    augenrules --load
else
    service auditd restart
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
printf 'export PATH=/opt/busybox:$PATH' >> /etc/profile
export PATH=/opt/busybox:$PATH
printf "==> Replacing /bin/false\n"
ln -sf /opt/busybox/false /bin/false

printf "[DONE] Log out if using ssh and log back in to activate busybox\n"


############################
# Running autofirewall.sh
############################

printf "Starting autofirewall.sh\n"
/var/tmp/autofirewall.sh 2>&1 | tee /var/tmp/.log/autofirewall.log
printf "Finished autofirewall.sh\n"

############################
# Running harden.sh
############################

printf "Starting harden.sh\n"
/var/tmp/harden.sh "$1" 2>&1 | tee /var/tmp/.log/harden.log
printf "Finished harden.sh\n"

printf "Finished activation script\n"
printf "Check out the baselining scripts standard.sh and specific.sh\n"
