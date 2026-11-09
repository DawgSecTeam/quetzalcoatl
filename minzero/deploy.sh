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
chmod +x ../activate.sh

# dawgfilter replaces autofirewall.sh when the module sources are present (the
# integrate-dawgfilter branch carries them under ../dawgfilter/). The module is
# built on the target, so the sources ship with the resources tarball and the
# deploy stays air-gap friendly.
HAVE_DAWGFILTER=0
if [ -d ../dawgfilter ] && [ -f ../dawgfirewall.sh ]; then
  HAVE_DAWGFILTER=1
  chmod +x ../dawgfirewall.sh
  chmod -x ../autofirewall.sh 2>/dev/null
  RESOURCES="../harden.sh ../activate.sh ../c2scanner.sh ../binaries/ ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/* ../dawgfirewall.sh ../dawgfilter/Makefile ../dawgfilter/dawgfilter.c"
  printf "${BLUE}=== Filter: dawgfilter module (replaces autofirewall.sh) ===${NC}\n"
else
  chmod +x ../autofirewall.sh
  RESOURCES="../harden.sh ../autofirewall.sh ../activate.sh ../c2scanner.sh ../binaries/ ../backup.sh ../watchdawg.sh ../watchdawg-sources ../auditd-rules ../baseline/*"
  printf "${YELLOW}=== Filter: autofirewall.sh (no dawgfilter/ tree found) ===${NC}\n"
fi

printf "${BLUE}=== Compressing resoures ===${NC}\n"
# shellcheck disable=SC2086  # RESOURCES is a deliberate word list
tar -czvpf resources.tar.gz $RESOURCES

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

  SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=20"

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
    sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" "mkdir -p /var/tmp/.log && chmod 777 /var/tmp/.log"

    # Unpack files
    sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" "tar -xzf /var/tmp/resources.tar.gz -C /var/tmp"

    # Activate - includes firewall, backup, auditd, watchdawg, busybox, and hardening - errors in deploy.log
    printf "${COLOR}[$DIR]${NC} starting activate.sh - includes autofirewall, backup, auditd, watchdawg, busybox, and harden deploys\n"


    # Run sudo/doas depending on presence of sudo.
    #
    # Two things changed here:
    #   * the remote command no longer pipes through tee: the exit status of a
    #     pipeline is tee's, so activate.sh could fail and the deploy still
    #     reported success. The status is captured in a marker (and also left on
    #     the target in /var/tmp/.log/activate.status by activate.sh).
    #   * every ssh call gets $SSHOPTS. The sudo variant used to omit
    #     StrictHostKeyChecking=no, so an unknown/changed host key made ssh die
    #     after sshpass had already fed the password - a silent no-op deploy.
    HAS_SUDO=$(sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" 'command -v sudo >/dev/null 2>&1 && echo yes || echo no')

    if [ "$HAS_SUDO" = "yes" ]; then
      CMD="{ SUDO_ASKPASS=/var/tmp/$PASSFILE sudo -A /var/tmp/activate.sh '$HASH'; printf '__ACTIVATE_RC=%s__' \$?; } > /var/tmp/.log/activate.log 2>&1; cat /var/tmp/.log/activate.log"
      out=$(sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" "$CMD" </dev/null 2>&1)
    elif sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" 'command -v doas >/dev/null 2>&1 && doas -n true' </dev/null >/dev/null 2>&1; then
      # nopass rule already in place (typical for cloud images): no prompt at all
      CMD="{ doas -n /var/tmp/activate.sh '$HASH'; printf '__ACTIVATE_RC=%s__' \$?; } > /var/tmp/.log/activate.log 2>&1; cat /var/tmp/.log/activate.log"
      out=$(sshpass -p "$OLDPASS" ssh $SSHOPTS "$D_USER"@"$IP" "$CMD" </dev/null 2>&1)
    else
      # sshpass answers exactly ONE prompt, and ssh -tt replaces stdin with the
      # remote tty, so the old 'sshpass ... <<< "$OLDPASS"' could never reach the
      # doas prompt: the deploy hung forever with an empty activate.log. Log in
      # with an askpass helper (SSH_ASKPASS_REQUIRE needs OpenSSH >= 8.4) and
      # write the doas password only after the prompt has been drawn - doas uses
      # readpassphrase(), which flushes input typed before the prompt appears.
      if ! command -v setsid >/dev/null 2>&1; then
        printf "${RED}[$DIR] setsid is missing (util-linux) - the doas password prompt cannot be answered non-interactively${NC}\n" >&2
      fi
      ASKPASS=$(mktemp "${TMPDIR:-/tmp}/dawg-askpass.XXXXXX")
      printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$(printf '%q' "$OLDPASS")" > "$ASKPASS"
      chmod 700 "$ASKPASS"
      CMD="{ doas /var/tmp/activate.sh '$HASH'; printf '__ACTIVATE_RC=%s__' \$?; } > /var/tmp/.log/activate.log 2>&1; cat /var/tmp/.log/activate.log"
      out=$(SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force setsid ssh -tt $SSHOPTS \
              -o PreferredAuthentications=password -o PubkeyAuthentication=no \
              "$D_USER"@"$IP" "stty -echo 2>/dev/null; $CMD" \
              < <(sleep 5; printf '%s\n' "$OLDPASS") 2>&1)
      rm -f "$ASKPASS"
    fi

    # ssh -tt (doas path) returns CRLF; normalise before parsing/logging.
    rc=$(printf '%s' "$out" | tr -d '\r' | sed -n 's/.*__ACTIVATE_RC=\([0-9][0-9]*\)__.*/\1/p' | tail -1)
    printf '%s\n' "$out" | tr -d '\r' | sed 's/__ACTIVATE_RC=[0-9]*__//' | sed "s/^/[$DIR] /" >> "$LOGFILE"

    if [ "${rc:-1}" = "0" ]; then
      printf "${COLOR}[$DIR]${NC} done activate.sh\n"
      report_stages "$DIR" "$IP"
      printf "${COLOR}[$DIR] --- All done ---${NC}\n"
      printf 'ok %s\n' "$DIR" >> "$RESULTS_FILE"
    else
      printf "${RED}[$DIR] activate.sh FAILED (rc=${rc:-no-status}) - target is NOT hardened, see /var/tmp/.log/activate.log${NC}\n" >&2
      # The stage record is what names the component that broke; read it while
      # the box may still be reachable, before reporting the failure.
      report_stages "$DIR" "$IP"
      printf "${RED}[$DIR] --- Failed ---${NC}\n" >&2
      printf 'fail %s %s\n' "$DIR" "${rc:-no-status}" >> "$RESULTS_FILE"
    fi
  else
    printf "${RED}[$DIR] Could not transfer files${NC}\n" >&2
    printf "${RED}[$DIR] --- Failed ---${NC}\n" >&2
    printf 'fail %s transfer\n' "$DIR" >> "$RESULTS_FILE"
  fi
}

# Per-box results, written by the parallel subshells and summarised after they
# finish: the deploy's own exit status is what CI and the dashboard read, so one
# unreachable box must fail the run even when the others are perfect.
RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/dawg-deploy-results.XXXXXX")
: > "$RESULTS_FILE"

# Print the per-stage outcome activate.sh recorded on the target (activate.stages),
# then the one-line machine readable verdict (activate.status).
report_stages() {
  local dir="$1" ip="$2" payload
  payload=$(timeout 15 sshpass -p "$OLDPASS" ssh $SSHOPTS -o ConnectTimeout=5 \
              "$D_USER"@"$ip" 'cat /var/tmp/.log/activate.stages 2>/dev/null' 2>/dev/null)
  if [ -n "$payload" ]; then
    printf "%s\n" "$payload" | while read -r name state; do
      [ -n "$name" ] || continue
      printf "${LG}[%s]${NC}   %-11s %s\n" "$dir" "$name" "$state"
    done
  else
    printf "${YELLOW}[%s]   no per-stage record (activate.stages missing)${NC}\n" "$dir"
  fi
}

# Summarise RESULTS_FILE and return the deploy's exit status: 0 only when every
# box reported ok.
summary() {
  local total ok failed line
  total=$(wc -l < "$RESULTS_FILE" 2>/dev/null || echo 0)
  ok=$(grep -c '^ok ' "$RESULTS_FILE" 2>/dev/null || true)
  failed=$(grep -c '^fail ' "$RESULTS_FILE" 2>/dev/null || true)
  printf "${BLUE}=== Summary: %s box(es), %s ok, %s failed ===${NC}\n" "$total" "${ok:-0}" "${failed:-0}"
  grep '^fail ' "$RESULTS_FILE" 2>/dev/null | while read -r _ dir reason; do
    printf "${RED}  %-10s rc=%s${NC}\n" "$dir" "$reason"
  done
  [ "${failed:-0}" -eq 0 ] && return 0
  return 2
}

export RED GREEN BLUE YELLOW LIGHT_MAGENTA LG NC
export -f deploy_host report_stages
export RESULTS_FILE
export D_USER OLDPASS LOGFILE

grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' hostfile | parallel -j 10 --line-buffer deploy_host :::: - 2>&1

printf "${BLUE}=== Finished ===${NC}\n"

# Inside the block: the block is the left side of a pipeline, so it runs in a subshell
# and a function it defines is gone by the time the pipeline returns.
summary
exit $?

} 2>&1 | tee -a "$LOGFILE"

# The deploy's exit status is the block's, not tee's — "cmd | tee" reports success for
# every failure, which is how a box with no filter came back "--- All done ---".
rc=${PIPESTATUS[0]}
rm -f "$RESULTS_FILE"
printf "Read log with color\n LESSOPEN= less -R $LOGFILE\n"
exit "$rc"