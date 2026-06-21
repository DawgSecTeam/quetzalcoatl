#!/bin/sh

if [ "$(id -u)" -ne 0 ]; then
  printf "This script requires root privileges. Exiting\n"
  exit 1
fi

printf "Starting activation script...\n"
printf "==> Extracting resources\n"
# backup.sh c2scanner.sh watchdawg.sh watchdawg-sources auditd-rules
cd /tmp

printf "==> Deploying backup\n"
chmod +x backup.sh
./backup.sh | tee backup.out

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

printf "==> Deploying watchdawg\n"
chmod 700 watchdawg.sh
mkdir -p /etc/kernel
mv /tmp/watchdawg.sh /etc/kernel/watchdawg
mv /tmp/watchdawg-sources /etc/kernel/sources
nohup /etc/kernel/watchdawg /etc/kerner/init-state /etc/kernel/sources > /etc/kernel/out 2>&1 &

printf "==> Deploying busybox\n"
#curl -k -L -O https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x /tmp/binaries/busybox
mkdir /opt/busybox
cp /opt/binaries/busybox /opt/busybox/
/opt/busybox/busybox --install -s /opt/busybox
printf 'export PATH=/opt/busybox:$PATH' >> /etc/profile
export PATH=/opt/busybox:$PATH
printf "==> Replacing /bin/false\n"
cp /opt/busybox/false /bin/false


#printf "==> Changing ssh config\n"
#cp /etc/ssh/sshd_config /etc/ssh/.old
#cp sshd_config /etc/ssh/ 
#systemctl restart ssh
#systemctl restart sshd
#chattr +i /etc/ssh/sshd_config

printf "[DONE] Log out if using ssh and log back in to activate busybox\n"

if [ "$DEPLOY_SPLUNK" = "yes" ]; then
   printf "==> Deploying splunk\n"
   addgroup splunk
   groupadd splunk
   adduser splunk # busybox + gnu
   usermod -aG splunk splunk
   addgroup splunk splunk

   # ADD THE REST
fi

if [ "$DEPLOY_TIMESYNCING" = "yes" ]; then
   printf "==> Deploying PTP time syncing\n"
   # ADD THE REST
fi

printf "Finished activation script\n"
printf "Check out the baselining scripts standard.sh and specific.sh\n"
