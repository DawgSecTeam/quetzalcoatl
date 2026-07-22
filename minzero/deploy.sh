#!/bin/bash

C=$(printf '\033')
RED="${C}[1;31m"
GREEN="${C}[1;32m"
BLUE="${C}[1;34m"
YELLOW="${C}[1;33m"
LIGHT_MAGENTA="${C}[1;95m"
LG="${C}[1;37m" #LightGray
NC="${C}[0m"

LOGFILE="deploy.log"
{
printf "${BLUE}=== Starting deployment script ===${NC}\n"

chmod +x harden.sh
chmod +x autofirewall.sh
chmod +x ../activate.sh

printf "${BLUE}=== Compressing resoures ===${NC}\n"
tar -czvpf resources.tar.gz harden.sh autofirewall.sh ../activate.sh ../c2scanner.sh ../binaries/ ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/*

printf "${BLUE}=== Running deploy ===${NC}\n"
deploy_host() {
  COLORS=("$RED" "$GREEN" "$YELLOW" "$LIGHT_MAGENTA" "$LG")
  #COLOR="${COLORS[$(($RANDOM % ${#COLORS[@]}))]}"
  COLOR="$GREEN"

  line="$1"
  DIR=$(echo "$line" | cut -d' ' -f1)
  IP=$(echo "$line" | cut -d' ' -f2)
  D_USER=$(echo "$line" | cut -d' ' -f3)
  OLDPASS=$(echo "$line" | cut -d' ' -f4)
  HASH=$(echo "$line" | cut -d' ' -f5)

  PASSFILE="pass_$DIR"
  cat > "$PASSFILE" <<EOF
#!/bin/sh
printf '%s\n' "$OLDPASS"
EOF
  chmod +x "$PASSFILE"

  printf "${COLOR}[$DIR]${NC} Begin system $IP with user $D_USER\n"
  AbsPath=$(realpath ../systems/)


  # Copy over files
  sshpass -p "$OLDPASS" scp -rpo StrictHostKeyChecking=no "$PASSFILE" resources.tar.gz "$AbsPath/$DIR/port-sources" "$AbsPath/$DIR" "$D_USER@$IP:/var/tmp/"

  if [ $? -eq 0 ]; then
    printf "${COLOR}[$DIR]${NC} Files transferred successfully.\n"

    # Create remote logging directory
    sshpass -p "$OLDPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "mkdir -p /var/tmp/.log"


    # unpack files
    sshpass -p "$OLDPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "tar -xzf /var/tmp/resources.tar.gz -C /var/tmp"

    # firewall
    printf "${COLOR}[$DIR]${NC} starting autofirewall.sh\n"
    sshpass -p "$OLDPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/autofirewall.sh | tee /var/tmp/.log/autofirewall.log" < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} done autofirewall.sh\n"

    # activate
    printf "${COLOR}[$DIR]${NC} starting activate.sh - includes backup, auditd, watchdawg, and busybox deploys\n"
    sshpass -p "$OLDPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/activate.sh | tee /var/tmp/.log/activate.log" < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} done activate.sh\n"

    # hardening
    printf "${COLOR}[$DIR]${NC} starting harden.sh\n"
    sshpass -p "$OLDPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/harden.sh '$HASH' | tee /var/tmp/.log/harden.log" < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} done harden.sh\n"

    # remove password from remote
    sshpass -p "$OLDPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A rm /var/tmp/$PASSFILE" < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} removed password file from remote\n"


    printf "${COLOR}[$DIR] --- All done ---${NC}\n"
  else
    printf "${RED}[$DIR] Could not transfer files${NC}\n" >&2
    printf "${RED}[$DIR] --- Failed ---${NC}\n" >&2
  fi
}

export RED GREEN BLUE YELLOW LIGHT_MAGENTA LG NC
export -f deploy_host
export D_USER OLDPASS

parallel -j 10 --line-buffer deploy_host :::: hostfile 2>&1

printf "${BLUE}=== Finished ===${NC}\n"

} 2>&1 | tee -a "$LOGFILE"

printf "Read log with color\n LESSOPEN= less -R $LOGFILE\n"