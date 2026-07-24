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

chmod +x ../harden.sh
chmod +x ../autofirewall.sh
chmod +x ../activate.sh

printf "${BLUE}=== Compressing resoures ===${NC}\n"
tar -czvpf resources.tar.gz ../harden.sh ../autofirewall.sh ../activate.sh ../c2scanner.sh ../binaries/ ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/*

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
    sshpass -p "$OLDPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "mkdir -p /var/tmp/.log && chmod 777 /var/tmp/.log"

    # Unpack files
    sshpass -p "$OLDPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "tar -xzf /var/tmp/resources.tar.gz -C /var/tmp"

    # Activate - includes firewall, backup, auditd, watchdawg, busybox, and hardening - errors in deploy.log
    printf "${COLOR}[$DIR]${NC} starting activate.sh - includes autofirewall, backup, auditd, watchdawg, busybox, and harden deploys\n"


    # Run sudo/doas depending on presence of sudo
    HAS_SUDO=$(sshpass -p "$OLDPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" 'command -v sudo >/dev/null 2>&1 && echo yes || echo no')

    if [ "$HAS_SUDO" = "yes" ]; then
      sshpass -p "$OLDPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/activate.sh '$HASH' 2>&1 | tee /var/tmp/.log/activate.log" < /dev/null \
        2>&1 | sed "s/^/[$DIR] /" >> "$LOGFILE"
    else
      sshpass -p "$OLDPASS" ssh -tt -o StrictHostKeyChecking=no "$D_USER"@"$IP" "doas /var/tmp/activate.sh '$HASH' 2>&1 | tee /var/tmp/.log/activate.log" \
        <<< "$OLDPASS" 2>&1 | sed "s/^/[$DIR] /" >> "$LOGFILE"
    fi

    printf "${COLOR}[$DIR]${NC} done activate.sh\n"

    printf "${COLOR}[$DIR] --- All done ---${NC}\n"
  else
    printf "${RED}[$DIR] Could not transfer files${NC}\n" >&2
    printf "${RED}[$DIR] --- Failed ---${NC}\n" >&2
  fi
}

export RED GREEN BLUE YELLOW LIGHT_MAGENTA LG NC
export -f deploy_host
export D_USER OLDPASS LOGFILE

parallel -j 10 --line-buffer deploy_host :::: hostfile 2>&1

printf "${BLUE}=== Finished ===${NC}\n"

} 2>&1 | tee -a "$LOGFILE"

printf "Read log with color\n LESSOPEN= less -R $LOGFILE\n"