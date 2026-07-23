#!/bin/sh

C=$(printf '\033')
RED="${C}[1;31m"
GREEN="${C}[1;32m"
YELLOW="${C}[1;33m"
BLUE="${C}[1;34m"
LG="${C}[1;37m"
NC="${C}[0m"

# Enable logging
if [ -z "$BASELINE_LOGGING" ]; then
   printf "Logging to /var/tmp/.log/baseline-specific.sh\n"
   LOGFILE="/var/tmp/.log/baseline-specific.sh"
   export BASELINE_LOGGING=1
   printf "${YELLOW}Logging session to %s${NC}\n" "$LOGFILE"
   exec sh -c "\"$0\" $* 2>&1 | tee \"$LOGFILE\""
fi

printf "▗▄▄▖  ▗▄▖  ▗▄▄▖▗▄▄▄▖▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖     ▗▄▄▖▗▄▄▖ ▗▄▄▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▄▄▖ ▗▄▄▖\n";
printf "▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌   ▐▌     █  ▐▛▚▖▐▌▐▌       ▐▌   ▐▌ ▐▌▐▌   ▐▌     █  ▐▌     █  ▐▌   \n";
printf "▐▛▀▚▖▐▛▀▜▌ ▝▀▚▖▐▛▀▀▘▐▌     █  ▐▌ ▝▜▌▐▛▀▀▘     ▝▀▚▖▐▛▀▘ ▐▛▀▀▘▐▌     █  ▐▛▀▀▘  █  ▐▌   \n";
printf "▐▙▄▞▘▐▌ ▐▌▗▄▄▞▘▐▙▄▄▖▐▙▄▄▖▗▄█▄▖▐▌  ▐▌▐▙▄▄▖    ▗▄▄▞▘▐▌   ▐▙▄▄▖▝▚▄▄▖▗▄█▄▖▐▌   ▗▄█▄▖▝▚▄▄▖\n\n";
printf " ====================================================================== v0.1.2 ===== \n\n";

# Changelog
# v0.1.1 - add sudoers check
#        - fixed mismatched directories
# v0.1.2 - updated dirs to match new backup.sh system
#        - add logging

printf "\nStarting specific baseline\n\n"

interact() {
   printf "%s\n" "${LG}Press enter to continue${NC}"
   read ans
}

printf "${BLUE}==> Running baseline collection on this compromised system${NC}\n"
chmod +x ../backup.sh
../backup.sh baseline

printf "${BLUE}==> Decompressing files${NC}\n"
rm -rf /var/tmp/sys-clean /var/tmp/sys-dirty
mkdir -p /var/tmp/sys-clean /var/tmp/sys-dirty
tar -xpzf /var/tmp/*/baseline.tar.gz -C /var/tmp/sys-clean
tar -xpzf /var/tmp/baseline.tar.gz -C /var/tmp/sys-dirty

CLEAN=/var/tmp/sys-clean/baseline
DIRTY=/var/tmp/sys-dirty/baseline

printf "${BLUE}==> Starting interactive baselining script.\nClean system is on the left, this system on the right\n"

interact

printf "${BLUE}Showing kernel modules${NC}\n"
diff -y $CLEAN/kernelmodules.txt $DIRTY/kernelmodules.txt | less

interact

printf "${BLUE}Showing active services${NC}\n"
diff -y $CLEAN/services-active_running.txt $DIRTY/services-active_running.txt | less
printf "${BLUE}Showing startup services${NC}\n"
diff -y $CLEAN/services-enabled_autostart.txt $DIRTY/services-enabled_autostart.txt | less

interact

printf "${BLUE}Showing installed packages${NC}\n"
diff -y $CLEAN/packages.txt $DIRTY/packages.txt | less

interact

printf "${BLUE}Showing suid bits${NC}\n"
diff -y $CLEAN/suidbits.txt $DIRTY/suidbits.txt | less

interact

printf "${BLUE}Showing open ports${NC}\n"
diff -y $CLEAN/listeningports.txt $DIRTY/listeningports.txt | less

interact

printf "${BLUE}Showing environmental variable${NC}\n"
diff -y $CLEAN/environmentalvariables.txt $DIRTY/environmentalvariables.txt | less

interact

printf "${BLUE}Showing PAM directory configurations\n"
diff -ry $CLEAN/filesystem/etc/pam.d $DIRTY/filesystem/etc/pam.d | less

interact

printf "${BLUE}Showing sudoers file\n"
diff -r $CLEAN/filesystem/etc/sudoers $DIRTY/filesystem/etc/sudoers | less

interact

printf "${GREEN}Done with basic baselining.\n"
printf "Exit the script now or continue to baselines for the entire /etc directory. It is recommended to secure your scored/network-exposed services before continuing.\n\n"

interact

printf "${BLUE}Showing ALL diffs in the /etc directory\n"
diff -ry $CLEAN/filesystem/etc $DIRTY/filesystem/etc | less
