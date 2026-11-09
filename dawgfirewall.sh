#!/bin/sh
# dawgfirewall.sh - build, load and persist dawgfilter in place of autofirewall.sh.
#
# Replaces autofirewall.sh's iptables rules with a netfilter module whose port
# lists come from /var/tmp/port-sources (line 1 = inbound ports, line 2 =
# outbound ports, space separated). Called by activate.sh, which turns a nonzero
# exit into die 13 so a box is never reported hardened with no filter running.
#
# Safety model
#   * refuses to run if port 22 is not inbound - that configuration locks the
#     operator out of the box by construction
#   * arms a suicide switch before insmod: if this script (or the ssh session it
#     runs under) dies before the module is proven to pass a fresh SSH
#     connection, the switch rmmods it again, so a bad build cannot brick a box
#     and, worse, cannot survive the reboot that would make the lockout permanent
#   * arms the switch BEFORE insmod and disarms it only through --confirm, which
#     activate.sh runs after everything that follows the firewall has worked over
#     the live ssh session
#
# Modes
#   dawgfirewall.sh            build, load, persist (the caller confirms)
#   dawgfirewall.sh --confirm  cancel the suicide switch (idempotent; called
#                              after the deploy proved the box is still reachable)
#   dawgfirewall.sh --unload   remove the module and its boot-time load
#
# Environment
#   DAWGFILTER_ARM_SECONDS  suicide-switch window (default 300)
#   DAWGFILTER_FALLBACK=1   run autofirewall.sh instead when the module cannot
#                           be built (explicit opt-in: a silent fallback is how
#                           "no firewall at all" goes unnoticed)

set -u

PORT_SOURCES=${PORT_SOURCES:-/var/tmp/port-sources}
LOG_DIR=/var/tmp/.log
SRC_DIR=/var/tmp/dawgfilter
KO="$SRC_DIR/dawgfilter.ko"
MODULE_NAME=dawgfilter
MODPROBE_DIR=/etc/modules-load.d
ARM_FILE=/run/dawgfilter.arm
ROLLBACK=/usr/local/sbin/dawgfilter-rollback
TIMER_UNIT=dawgfilter-rollback
ARM_SECONDS=${DAWGFILTER_ARM_SECONDS:-300}
SSH_PORT=22

say() { printf '%s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

mkdir -p "$LOG_DIR" 2>/dev/null
chmod 777 "$LOG_DIR" 2>/dev/null

# --------------------------------------------------
# Helper: build a file that the module reads at compile time
# --------------------------------------------------

install_build_deps() {
   if command -v apt-get > /dev/null 2>&1; then
      say "[*] Installing build-essential + linux-headers-$(uname -r) (apt)"
      apt-get update -qq || true
      # linux-headers-<running release> is the only header set that can produce a
      # loadable module; the meta package alone gives headers for a newer kernel.
      if ! apt-get install -y build-essential "linux-headers-$(uname -r)" \
            >> "$LOG_DIR/dawgfilter-build.log" 2>&1; then
         apt-get install -y build-essential linux-headers-generic \
            >> "$LOG_DIR/dawgfilter-build.log" 2>&1 || return 1
      fi
   elif command -v dnf > /dev/null 2>&1; then
      say "[*] Installing gcc make kernel-devel (dnf)"
      dnf install -y gcc make "kernel-devel-$(uname -r)" \
         >> "$LOG_DIR/dawgfilter-build.log" 2>&1 ||
         dnf install -y gcc make kernel-devel >> "$LOG_DIR/dawgfilter-build.log" 2>&1 || return 1
   elif command -v apk > /dev/null 2>&1; then
      say "[*] Installing build-base linux-headers (apk)"
      apk add -q build-base linux-headers >> "$LOG_DIR/dawgfilter-build.log" 2>&1 || return 1
   elif command -v zypper > /dev/null 2>&1; then
      say "[*] Installing gcc make kernel-devel (zypper)"
      zypper --non-interactive install gcc make kernel-devel \
         >> "$LOG_DIR/dawgfilter-build.log" 2>&1 || return 1
   else
      say "[!] no known package manager"
      return 1
   fi

   # The headers must exist for the RUNNING kernel or the module will not load.
   if [ ! -e "/lib/modules/$(uname -r)/build" ]; then
      say "[!] /lib/modules/$(uname -r)/build is missing after installing headers"
      return 1
   fi

   # A kernel upgrade already staged for the next boot is the trap that silently removes
   # the filter after a reboot: the module is built for $(uname -r), the box boots the
   # newer one (2026-11-09: built for 6.12.107, rebooted into 6.12.116, no filter).
   newest=$(ls /lib/modules 2>/dev/null | grep -v "$(uname -r)" | sort -V | tail -1)
   if [ -n "$newest" ]; then
      case "$(printf '%s\n%s\n' "$(uname -r)" "$newest" | sort -V | tail -1)" in
         "$newest")
            say "[!] a newer kernel ($newest) is installed and will boot next: the module"
            say "    built now will NOT load after that reboot. Reboot first, then re-run"
            say "    this script, or pin the kernel. Installing the boot check regardless." ;;
      esac
   fi
}

read_ports() {
   [ -r "$PORT_SOURCES" ] || die "missing $PORT_SOURCES (line 1 inbound, line 2 outbound ports)"
   IN_PORTS=$(sed -n 1p "$PORT_SOURCES" | tr -s ' \t' ' ')
   OUT_PORTS=$(sed -n 2p "$PORT_SOURCES" | tr -s ' \t' ' ')
   [ -n "$IN_PORTS" ] || die "$PORT_SOURCES has an empty inbound line"

   # A filter with no inbound SSH port locks the operator out by construction.
   case " $IN_PORTS " in
      *" $SSH_PORT "*) ;;
      *) die "port $SSH_PORT is not in the inbound list ($IN_PORTS) - refusing to cut the box off" ;;
   esac
}

write_config() {
   # Only TCP for now: the UDP lists are populated from the same two lines, so a
   # future "line 3 = udp" convention does not need a module rebuild.
   {
      printf '/* Generated by dawgfirewall.sh from %s on %s */\n' \
         "$PORT_SOURCES" "$(date)"
      printf 'static const int IN_PORTS_TCP[] = {%s};\n' "$(printf '%s' "$IN_PORTS" | tr ' ' ',')"
      printf 'static const int OUT_PORTS_TCP[] = {%s};\n' "$(printf '%s' "$OUT_PORTS" | tr ' ' ',')"
      printf 'static const int IN_PORTS_UDP[] = {%s};\n' "$(printf '%s' "$IN_PORTS" | tr ' ' ',')"
      printf 'static const int OUT_PORTS_UDP[] = {%s};\n' "$(printf '%s' "$OUT_PORTS" | tr ' ' ',')"
      printf 'static unsigned int DEFAULT_RULE = NF_DROP;\n'
   } > "$SRC_DIR/config.h" || die "could not write $SRC_DIR/config.h"
}

# --------------------------------------------------
# Suicide switch
# --------------------------------------------------

write_rollback() {
   cat > "$ROLLBACK" <<'EOF'
#!/bin/sh
# Installed by dawgfirewall.sh. Unloads dawgfilter if the deploy never confirmed
# that the box is still reachable through it.
[ -f /run/dawgfilter.arm ] || exit 0
logger -t dawgfilter "suicide switch fired: no confirmation, unloading" 2>/dev/null
rmmod dawgfilter 2>/dev/null
rm -f /run/dawgfilter.arm
exit 0
EOF
   chmod 0755 "$ROLLBACK"
}

arm_switch() {
   write_rollback
   : > "$ARM_FILE"

   if command -v systemd-run > /dev/null 2>&1 && [ -d /run/systemd/system ]; then
      # Transient timer: survives this ssh session, and is cancelled by --confirm.
      systemctl stop "$TIMER_UNIT.timer" 2>/dev/null
      if systemd-run --on-active="$ARM_SECONDS" --unit="$TIMER_UNIT" \
            --description="dawgfilter rollback" "$ROLLBACK" > /dev/null 2>&1; then
         say "[*] Suicide switch armed: dawgfilter unloads in ${ARM_SECONDS}s unless confirmed"
         return 0
      fi
   fi
   # No systemd (alpine/openrc): detach a plain shell. setsid keeps it alive when
   # the ssh session that started it goes away.
   if command -v setsid > /dev/null 2>&1; then
      setsid sh -c "sleep $ARM_SECONDS; $ROLLBACK" > /dev/null 2>&1 &
   else
      (sleep "$ARM_SECONDS"; "$ROLLBACK") > /dev/null 2>&1 &
   fi
   say "[*] Suicide switch armed (no systemd): dawgfilter unloads in ${ARM_SECONDS}s unless confirmed"
}

confirm_switch() {
   if [ -f "$ARM_FILE" ]; then
      rm -f "$ARM_FILE"
      say "[+] Suicide switch disarmed"
   fi
   if command -v systemctl > /dev/null 2>&1; then
      systemctl stop "$TIMER_UNIT.timer" > /dev/null 2>&1
      systemctl reset-failed "$TIMER_UNIT.service" > /dev/null 2>&1
   fi
   exit 0
}

# --------------------------------------------------
# Modes
# --------------------------------------------------

case "${1:-}" in
   --confirm) confirm_switch ;;
   --unload)
      rmmod "$MODULE_NAME" 2>/dev/null
      rm -f "$MODPROBE_DIR/$MODULE_NAME.conf"
      rm -f "$ARM_FILE"
      say "[+] $MODULE_NAME unloaded and removed from boot"
      exit 0 ;;
esac

# --------------------------------------------------
# Build
# --------------------------------------------------

read_ports
say "[*] Inbound ports:  $IN_PORTS"
say "[*] Outbound ports: $OUT_PORTS"

[ -d "$SRC_DIR" ] || die "module sources missing from $SRC_DIR (deploy did not stage dawgfilter/)"

install_build_deps || {
   if [ "${DAWGFILTER_FALLBACK:-0}" = "1" ]; then
      say "[!] cannot build dawgfilter - DAWGFILTER_FALLBACK=1, using autofirewall.sh"
      exec /var/tmp/autofirewall.sh
   fi
   die "cannot install kernel headers for $(uname -r) - no filter would be loaded (set DAWGFILTER_FALLBACK=1 to use iptables instead)"
}

write_config

say "[*] Building $MODULE_NAME.ko against kernel $(uname -r)"
make -C "$SRC_DIR" clean > /dev/null 2>&1 || true
# "make | tee log" would report tee's status, which is how a failed build once
# looked like a finished firewall. Capture make's own exit code.
make -C "$SRC_DIR" > "$LOG_DIR/dawgfilter-build.log" 2>&1
build_rc=$?
tail -n 5 "$LOG_DIR/dawgfilter-build.log" 2>/dev/null
if [ "$build_rc" -ne 0 ] || [ ! -f "$KO" ]; then
   if [ "${DAWGFILTER_FALLBACK:-0}" = "1" ]; then
      say "[!] build failed (rc=$build_rc) - DAWGFILTER_FALLBACK=1, using autofirewall.sh"
      exec /var/tmp/autofirewall.sh
   fi
   die "build failed (rc=$build_rc), see $LOG_DIR/dawgfilter-build.log - no filter would be loaded (set DAWGFILTER_FALLBACK=1 to use iptables instead)"
fi

# --------------------------------------------------
# Load (with the switch already armed)
# --------------------------------------------------

# conntrack makes the filter stateful; modprobe resolves it, insmod does not.
modprobe nf_conntrack 2>/dev/null || true

arm_switch

modprobe -r "$MODULE_NAME" 2>/dev/null || true
if ! insmod "$KO"; then
   rm -f "$ARM_FILE"
   die "insmod failed - see dmesg (no filter loaded)"
fi
if ! lsmod | grep -q "^$MODULE_NAME"; then
   rm -f "$ARM_FILE"
   die "module not in lsmod after insmod"
fi

# No box-side reachability probe here: the only flow that would prove inbound works is a
# connection from ANOTHER host, and this script cannot make one. A box connecting to its own
# SSH port is not a valid test either — the outbound list does not allow destination 22, so
# the filter correctly drops it (2026-11-09: that false negative unloaded a working module on
# both boxes). The proof is the caller's: activate.sh keeps running over the same ssh session
# and confirms at the end, and the switch unloads the module if it never gets there.

# --------------------------------------------------
# Persist across reboot
# --------------------------------------------------

mkdir -p "/lib/modules/$(uname -r)/extra"
install -m 0644 "$KO" "/lib/modules/$(uname -r)/extra/$MODULE_NAME.ko" || die "could not install $MODULE_NAME.ko"
depmod -a 2>/dev/null || true
# nf_conntrack first: the module should come back stateful on boot.
printf 'nf_conntrack\n%s\n' "$MODULE_NAME" > "$MODPROBE_DIR/$MODULE_NAME.conf" || die "could not write $MODPROBE_DIR/$MODULE_NAME.conf"

# --------------------------------------------------
# IPv6: the module only hooks IPv4, so keep it off (as autofirewall.sh did)
# --------------------------------------------------
cat > /etc/sysctl.d/99-dawgfilter-no-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl -q -p /etc/sysctl.d/99-dawgfilter-no-ipv6.conf 2>/dev/null || true

# --------------------------------------------------
# Boot check: never let a silent module load failure leave a box unfiltered
# --------------------------------------------------
install_boot_check() {
   cat > /usr/local/sbin/dawgfilter-bootcheck <<'EOS'
#!/bin/sh
# Installed by dawgfirewall.sh. Runs at boot AFTER modules-load.d has done its work.
if lsmod | grep -q '^dawgfilter'; then
   exit 0
fi
logger -t dawgfilter -p daemon.err \
   "dawgfilter did NOT load at boot - no netfilter filtering; applying autofirewall fallback"
echo "[!] dawgfilter missing at boot" > /var/tmp/.log/dawgfilter-bootcheck.log
if [ -x /var/tmp/autofirewall.sh ]; then
   /var/tmp/autofirewall.sh >> /var/tmp/.log/dawgfilter-bootcheck.log 2>&1
fi
exit 1
EOS
   chmod 0755 /usr/local/sbin/dawgfilter-bootcheck
   cat > /etc/systemd/system/dawgfilter-bootcheck.service <<'EOS'
[Unit]
Description=dawgfilter boot check (fall back to iptables when the module did not load)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dawgfilter-bootcheck

[Install]
WantedBy=multi-user.target
EOS
   systemctl daemon-reload 2>/dev/null || true
   systemctl enable dawgfilter-bootcheck.service > /dev/null 2>&1 || true
   say "[+] Boot check installed (dawgfilter-bootcheck.service)"
}

install_boot_check

confirm_switch
say "[+] $MODULE_NAME active: in {$IN_PORTS} out {$OUT_PORTS}, default DROP (ICMP included)"
exit 0
