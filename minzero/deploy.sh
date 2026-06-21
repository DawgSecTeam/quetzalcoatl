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

printf "${BLUE}=== Compressing resoures ===${NC}\n"
tar -czvf resources.tar.gz ../activate.sh ../c2scanner.sh ../binaries/* ../sshd_config ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/*

printf "${BLUE}=== Running deploy ===${NC}\n"
deploy_host() {
  COLORS=("$RED" "$GREEN" "$YELLOW" "$LIGHT_MAGENTA" "$LG")
  #COLOR="${COLORS[$(($RANDOM % ${#COLORS[@]}))]}"
  COLOR="$GREEN"

  line="$1"
  DIR=$(echo "$line" | cut -d' ' -f1)
  IP=$(echo "$line" | cut -d' ' -f2)
  USER=$(echo "$line" | cut -d' ' -f3)
  OLDPASS=$(echo "$line" | cut -d' ' -f4)
  HASH=$(echo "$line" | cut -d' ' -f5)

  PASSFILE="pass_$DIR"
  printf '#!/bin/sh\nprintf "%s\n" "%s"\n' "$OLDPASS" > "$PASSFILE"
  chmod +x "$PASSFILE"

  printf "${COLOR}[$DIR]${NC} Begin system $IP with user $USER\n"
  AbsPath=$(realpath ../systems/)


  # Copy over files
  sshpass -p "$OLDPASS" scp -ro StrictHostKeyChecking=no harden.sh "$PASSFILE" autofirewall.sh resources.tar.gz "$AbsPath/$DIR/port-sources" "$AbsPath/$DIR" "$USER@$IP:/tmp/"

  if [ $? -eq 0 ]; then
    printf "${COLOR}[$DIR]${NC} Files transferred successfully.\n"

    # firewall
    printf "${COLOR}[$DIR]${NC} starting autofirewall.sh\n"
    sshpass -p "$OLDPASS" ssh "$USER"@"$IP" 'SUDO_ASKPASS="/tmp/'"$PASSFILE"'" sudo -A /tmp/autofirewall.sh' < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} done autofirewall.sh\n"
    printf "${COLOR}[$DIR]${NC} starting harden.sh\n"

    # hardening
    sshpass -p "$OLDPASS" ssh "$USER"@"$IP" "SUDO_ASKPASS=/tmp/$PASSFILE sudo -A /tmp/harden.sh '$HASH'" < /dev/null \
      2>&1 | sed "s/^/[$DIR] /"
    printf "${COLOR}[$DIR]${NC} done harden.sh\n"

    printf "${COLOR}[$DIR] --- All done ---${NC}\n"

  else
    printf "${RED}[$DIR] Could not transfer files${NC}\n" >&2
    printf "${RED}[$DIR] --- Failed ---${NC}\n" >&2
  fi
}

export RED GREEN BLUE YELLOW LIGHT_MAGENTA LG NC
export -f deploy_host
export USER OLDPASS

parallel -j 10 --line-buffer deploy_host :::: hostfile

printf "${BLUE}=== Finished ===${NC}\n"

} 2>&1 | tee -a "$LOGFILE"
