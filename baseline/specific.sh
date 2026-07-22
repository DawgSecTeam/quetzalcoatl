#!/bin/sh
printf "▗▄▄▖  ▗▄▖  ▗▄▄▖▗▄▄▄▖▗▖   ▗▄▄▄▖▗▖  ▗▖▗▄▄▄▖     ▗▄▄▖▗▄▄▖ ▗▄▄▄▖ ▗▄▄▖▗▄▄▄▖▗▄▄▄▖▗▄▄▄▖ ▗▄▄▖\n";
printf "▐▌ ▐▌▐▌ ▐▌▐▌   ▐▌   ▐▌     █  ▐▛▚▖▐▌▐▌       ▐▌   ▐▌ ▐▌▐▌   ▐▌     █  ▐▌     █  ▐▌   \n";
printf "▐▛▀▚▖▐▛▀▜▌ ▝▀▚▖▐▛▀▀▘▐▌     █  ▐▌ ▝▜▌▐▛▀▀▘     ▝▀▚▖▐▛▀▘ ▐▛▀▀▘▐▌     █  ▐▛▀▀▘  █  ▐▌   \n";
printf "▐▙▄▞▘▐▌ ▐▌▗▄▄▞▘▐▙▄▄▖▐▙▄▄▖▗▄█▄▖▐▌  ▐▌▐▙▄▄▖    ▗▄▄▞▘▐▌   ▐▙▄▄▖▝▚▄▄▖▗▄█▄▖▐▌   ▗▄█▄▖▝▚▄▄▖\n\n";
printf " ====================================================================== v0.1.1 ===== \n\n";

# Changelog
# v0.1.1 - add sudoers check
#        - fixed mismatched directories

RED="${C}[1;31m"
GREEN="${C}[1;32m"
YELLOW="${C}[1;33m"
BLUE="${C}[1;34m"
LG="${C}[1;37m"
NC="${C}[0m"

printf "\nStarting specific baseline\n\n"

interact() {
   printf "%s " "${LG}Press enter to continue${NC}\n"
   read ans
}

printf "${BLUE}==> Running data collection script on this compromised system${NC}\n"
chmod +x data-collection.sh
./data-collection.sh

printf "${BLUE}==> Decompressing files${NC}\n"
tar -xpzf /var/tmp/*/baseline.tar.gz -C /var/tmp/sys-clean
tar -xpzf /var/tmp/baseline.tar.gz -C /var/tmp/sys-dirty

CLEAN=$(realpath ../sys-clean)
DIRTY=$(realpath ../sys-dirty)

printf "${BLUE}==> Starting interactive baselining script.\nClean system is on the left, this system on the right\n"

interact

printf "${BLUE}Showing kernel modules${NC}\n"
diff -y $CLEAN/kernelModules $DIRTY/kernelModules | less

interact

printf "${BLUE}Showing active services${NC}\n"
diff -y $CLEAN/servicesActiveRunning $DIRTY/servicesActiveRunning | less
printf "${BLUE}Showing startup services${NC}\n"
diff -y $CLEAN/servicesEnabledAutostart $DIRTY/servicesEnabledAutostart | less

interact

printf "${BLUE}Showing installed packages${NC}\n"
diff -y $CLEAN/packages $DIRTY/packages | less

interact

printf "${BLUE}Showing suid bits${NC}\n"
diff -y $CLEAN/suidbits $DIRTY/suidbits | less

interact

printf "${BLUE}Showing open ports${NC}\n"
diff -y $CLEAN/openPorts $DIRTY/openPorts | less

interact

printf "${BLUE}Showing environmental variable${NC}\n"
diff -y $CLEAN/environmentalVariables $DIRTY/environmentalVariables | less

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
