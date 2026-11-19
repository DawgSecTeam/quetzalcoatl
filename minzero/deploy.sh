#!/bin/bash

C=$(printf '\033')
RED="${C}[1;31m"
GREEN="${C}[1;32m"
BLUE="${C}[1;34m"
YELLOW="${C}[1;33m"
LIGHT_MAGENTA="${C}[1;95m"
LG="${C}[1;37m" #LightGray
NC="${C}[0m"

NEWPASS="${1:?Usage: $0 <new_password>}"
LOGFILE="deploy.log"
export START_TIME=$(date +%s)
{
printf "${BLUE}=== Starting deployment script ===${NC}\n"

chmod +x ../harden.sh
chmod +x ../autofirewall.sh
chmod +x ../activate.sh

printf "${BLUE}=== Compressing resoures ===${NC}\n"
tar -czvpf resources.tar.gz ../harden.sh ../autofirewall.sh ../activate.sh ../c2scanner.sh ../binaries/ ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/* ../configurations/*

printf "${BLUE}=== Running deploy ===${NC}\n"
deploy_host() {
  COLORS=("$RED" "$GREEN" "$YELLOW" "$LIGHT_MAGENTA" "$LG")
  #COLOR="${COLORS[$(($RANDOM % ${#COLORS[@]}))]}"
  COLOR="$GREEN"
  
  NEWPASS="$1"
  line="$2"
  DIR=$(echo "$line" | cut -d' ' -f1)
  IP=$(echo "$line" | cut -d' ' -f2)
  D_USER=$(echo "$line" | cut -d' ' -f3)
  OLDPASS=$(echo "$line" | cut -d' ' -f4)
  HASH=$(echo "$line" | cut -d' ' -f5)

  # Stage 1
  sshpass -p "asdf" ssh $D_USER@$IP "echo asdf | sudo -S sh -c \"echo sysadmin:$NEWPASS | sudo -S chpasswd\" "


  PASSFILE="pass_$DIR"
  cat > "$PASSFILE" <<EOF
#!/bin/sh
printf '%s\n' $NEWPASS
EOF
  chmod +x "$PASSFILE"

  printf "${COLOR}[$DIR]${NC} Begin system $IP with user $D_USER\n"
  AbsPath=$(realpath ../systems/)


  # Copy over files
  sshpass -p "$NEWPASS" scp -rpo StrictHostKeyChecking=no "$PASSFILE" resources.tar.gz "$AbsPath/$DIR/port-sources" "$AbsPath/$DIR" "$D_USER@$IP:/var/tmp/"

  # Run sudo/doas depending on presence of sudo
  HAS_SUDO=$(sshpass -p "$NEWPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" 'command -v sudo >/dev/null 2>&1 && echo yes || echo no')

  if [ "$HAS_SUDO" = "yes" ]; then

  # Check if tar exists
  sshpass -p "$NEWPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A sh -c ' 
  if ! command -v tar > /dev/null 2>&1; then
    printf \"Installing Tar\n\"
    if command -v dnf > /dev/null 2>&1; then
      dnf install tar -y
    elif command -v apt > /dev/null 2>&1; then
      apt install -y tar
    elif command -v apk > /dev/null 2>&1; then
      apk add -q tar
    elif command -v pacman > /dev/null 2>&1; then
      pacman -S --noconfirm tar
    fi
  fi
  '
  "
  fi

  if [ $? -eq 0 ]; then
    printf "${COLOR}[$DIR]${NC} Files transferred successfully.\n"

    # Create remote logging directory
    sshpass -p "$NEWPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "mkdir -p /var/tmp/.log && chmod 777 /var/tmp/.log"

    # Unpack files
    sshpass -p "$NEWPASS" ssh -o StrictHostKeyChecking=no "$D_USER"@"$IP" "tar -xzf /var/tmp/resources.tar.gz -C /var/tmp"

    ELAPSED=$(( $(date +%s) - START_TIME ))
    printf "${COLOR}[$DIR]${NC} Untarred on $IP in ${ELAPSED}s from script start.\n"
    # Activate - includes firewall, backup, auditd, watchdawg, busybox, and hardening - errors in deploy.log
    printf "${COLOR}[$DIR]${NC} starting activate.sh - includes autofirewall, backup, auditd, watchdawg, busybox, and harden deploys\n"


      if [ "$HAS_SUDO" = "yes" ]; then
      sshpass -p "$NEWPASS" ssh "$D_USER"@"$IP" "SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/activate.sh '$HASH' 2>&1 | tee /var/tmp/.log/activate.log" < /dev/null \
        2>&1 | sed "s/^/[$DIR] /" >> "$LOGFILE"
    else
      sshpass -p "$NEWPASS" ssh -tt -o StrictHostKeyChecking=no "$D_USER"@"$IP" "doas /var/tmp/activate.sh '$HASH' 2>&1 | tee /var/tmp/.log/activate.log" \
        <<< "$NEWPASS" 2>&1 | sed "s/^/[$DIR] /" >> "$LOGFILE"
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

grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' hostfile | parallel -j 10 --line-buffer deploy_host "$NEWPASS" :::: - 2>&1

printf "${BLUE}=== Finished ===${NC}\n"

} 2>&1 | tee -a "$LOGFILE"

printf "Read log with color\n LESSOPEN= less -R $LOGFILE\n"
