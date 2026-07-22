#!/bin/sh
printf "▗▄▄▖  ▗▄▖  ▗▄▄▖▗▄▄▄▖▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖     ▗▄▄▖▗▄▄▄▖▗▄▖ ▗▖  ▗▖▗▄▄▄  ▗▄▖ ▗▄▄▖ ▗▄▄▄ \n";
printf "▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌   ▐▌     █  ▐▛▚▖▐▌▐▌       ▐▌     █ ▐▌ ▐▌▐▛▚▖▐▌▐▌  █▐▌ ▐▌▐▌ ▐▌▐▌  █\n";
printf "▐▛▀▚▖▐▛▀▜▌ ▝▀▚▖▐▛▀▀▘▐▌     █  ▐▌ ▝▜▌▐▛▀▀▘     ▝▀▚▖  █ ▐▛▀▜▌▐▌ ▝▜▌▐▌  █▐▛▀▜▌▐▛▀▚▖▐▌  █\n";
printf "▐▙▄▞▘▐▌ ▐▌▗▄▄▞▘▐▙▄▄▖▐▙▄▄▖▗▄█▄▖▐▌  ▐▌▐▙▄▄▖    ▗▄▄▞▘  █ ▐▌ ▐▌▐▌  ▐▌▐▙▄▄▀▐▌ ▐▌▐▌ ▐▌▐▙▄▄▀\n\n";
printf " ====================================================================== v0.1.1 ===== \n\n";

# v0.1.1 - add interactions between checks
#        - remove duplicate cron checks
#        - show repos
#        - remove duplicate ld_preload check
#        - fix a ton of syntax errors in shell and curl

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    echo -e "\e[31mThis script must be run as root\e[0m" 1>&2
    exit 1
fi

interact() {
   printf "%s " "${LG}Press enter to continue${NC}\n"
   read ans
}

# ADD SOMETHING THAT SHOWS REPOS

# Colors
C=$(printf '\033')
RED="${C}[1;31m"
GREEN="${C}[1;32m"
YELLOW="${C}[1;33m"
BLUE="${C}[1;34m"
LG="${C}[1;37m" #LightGray
DG="${C}[1;90m" #DarkGray
NC="${C}[0m"

printf "${LG}GENERAL SYSTEM INFO${NC}\n"
cat /etc/os-release

interact

printf "${BLUE}Checking for preloaded libraries${NC}\n"
printf "$LD_PRELOAD\n"

interact

printf "${BLUE}Showing PATH variable (check for suspicious dirs)${NC}\n"
printf "$PATH\n"

interact

printf "${YELLOW}Is this system time correct?${NC}\n"
timedatectl

interact

printf "${BLUE}Checking open ports${NC}\n"
ss -tulpn
printf "${BLUE}Show processes running on ports${NC}\n"
sudo lsof -i -P -n

interact

printf "${BLUE}Checking iptable rules${NC}\n"
iptables -L

interact

printf "${BLUE}Checking only root has id ${NC}\n"
#awk -F: '($3 == "0") {print}' /etc/passwd
if [ $(awk -F: '($3 == 0 && $1 != "root")' /etc/passwd | wc -l) -gt 0 ]; then
    printf "${RED}Multiple UID 0 accounts found!${NC}\n"
fi

interact

printf "${BLUE}Checking for passwordless login through PAM${NC}\n"
if grep -Rq "nullok" /etc/pam.d; then
   printf "${RED}PASSWORDLESS AUTHENTICATION IS ENABLED IN PAM${NC}\nCheck the /etc/pam.d directory to secure it\n";
fi

interact

printf "${BLUE}Checking for nopasswd in sudoers files${NC}\n"
sudo grep "NOPASSWD" /etc/sudoers
sudo grep -R "NOPASSWD" /etc/sudoers.d/

interact

printf "${YELLOW}Listing priviledged users${NC}\n"
grep -Po '^sudo.+:\K.*$' /etc/group
grep -Po '^wheel.+:\K.*$' /etc/group
printf "${YELLOW}CHECK /etc/sudoers FILE FOR OTHER USERS WITH ROOT ACCESS${NC}\n"

interact

printf "${BLUE}Listing users without passwords${NC}\n"
if [ $(awk -F: '($2 == "") {print}' /etc/shadow | wc -l) -gt 0 ]; then
    printf "${RED}Users without password set!\n$(awk -F: '($2 == "") {print $1}' /etc/shadow)${NC}\n"
fi

interact

printf "${BLUE}Showing authorized SSH keys (concerning only systems with key-based auth enabled)${NC}\n"
printf "=== Root ===\n"
sudo cat /root/.ssh/authorized_keys
for user_dir in /home/*; do
   auth_file="$user_dir/.ssh/authorized_keys"
   if [ -f "$auth_file" ]; then
      printf "=== User: ${user_dir##*/} ===\n"
      cat "$auth_file"
   fi
done

interact

printf "${YELLOW}Checking for scripts in the /etc/init.d directory${NC}\n"
ls /etc/init.d

interact

printf "${BLUE}Searching for suspicious processes${NC}\n"
ps aux | grep -E 'nc|netcat|bash|python|perl|sh'

interact

printf "${BLUE}Show all crontabs and anacron${NC}\n"
cat /etc/crontab # system crontab
cat /etc/cron*/* # daily, weekly, etc
cat /var/spool/cron/crontabs/* # individual users, debian
cat /var/spool/cron/* # individual users, fedora
cat /etc/anacrontab # works across reboot

interact

printf "${BLUE}Showing at jobs${NC}\n"
atq

interact

printf "${BLUE}Showing systemd timers${NC}\n"
systemctl list-timers --all --no-pager

interact

printf "${BLUE}Showing package repositories${NC}\n"
if command -v dnf > /dev/null 2>&1; then
   dnf repolist
elif command -v apt > /dev/null 2>&1; then
   cat /etc/apt/sources.list
   cat /etc/apt/sources.list.d/ubuntu.sources
fi

interact

printf "${BLUE}Showing files at root of /etc/ dir that are world writable${NC}\n"
find /etc -maxdepth 1 -perm -o+w -ls

interact

printf "${BLUE}Checking Docker/Podman containers${NC}\n"
if command -v docker > /dev/null 2>&1; then
   sudo docker ps -a
elif command -v podman > /dev/null 2>&1; then
   sudo podman ps -a
fi

interact

printf "${BLUE}Checking package checksums${NC}\n"
if command -v dpkg > /dev/null 2>&1; then
   dpkg -V | grep -v missing
elif command -v apk > /dev/null 2>&1; then
   apk verify
elif command -v rpm > /dev/null 2>&1; then
   echo
   #rpm -Va | grep -v missing
fi

interact

printf "${BLUE}Checking for pwnkit vulnerability${NC}\n"
polkitVersion=$(systemctl status polkit.service 2>/dev/null | grep version | cut -d " " -f 9)
if [ "$(apt list --installed 2>/dev/null | grep polkit | grep -c 0.105-26)" -ge 1 ] || [ "$(rpm -qa | grep -i polkit | grep -ic "0.11[3-9]")" -ge 1 ]; then
   printf "${RED}SYSTEM MAY BE VULNERABLE TO PWNKIT\n"
   printf "RUN ${NC}sudo chmod -s $(which pkexec) ${RED}to mitigate${NC}\n"
fi

interact

printf "${BLUE}Checking for executables and scripts in /etc and /var${NC}\n"
sudo find /etc -type f -exec file {} + | grep "ELF"
sudo find /var -type f -exec file {} + | grep "ELF"
grep -rIl "^#!" /etc

interact

printf "${BLUE}Would you like to install lynis? (y/n)${NC}\n"
read INSTALL_LYNIS
if [ $INSTALL_LYNIS = "y" ]; then
   printf "${BLUE}Starting lynis, redirecting output to /var/tmp/lynis${NC}\n"
   if command -v dnf > /dev/null 2>&1; then
      sudo dnf install lynis -y
   elif command -v apt > /dev/null 2>&1; then
      sudo apt install lynis -y
   elif command -v apk > /dev/null 2>&1; then
      sudo apk install lynis
   fi
   nohup lynis audit system > /var/tmp/lynis 2>&1 &
fi

interact

printf "${BLUE}Starting linpeas, redircting output to /var/tmp/linpeas, output can be read with less -r${NC}\n"
#curl -L https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh -o /var/tmp/lp.sh
chmod +x /var/tmp/binaries/linpeas.sh
nohup /var/tmp/binaries/linpeas.sh > /var/tmp/linpeas 2>&1 &

interact

printf "${BLUE}Done. Check the tool output files once they finish scanning${NC}\n"


# TO-DO
# chkrootkit, rkhunter, clamav
