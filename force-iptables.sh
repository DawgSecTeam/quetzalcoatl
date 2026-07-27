#!/bin/sh
# force-iptables.sh — Persistent iptables rule enforcement daemon (Card 17)
#
# Continuously monitors and enforces desired iptables rules. If an attacker
# modifies the firewall, this daemon detects the drift and re-applies the
# correct rules within seconds.
#
# Usage:
#   ./force-iptables.sh --install    Start as a background daemon
#   ./force-iptables.sh --stop       Stop the daemon
#   ./force-iptables.sh --status     Check if daemon is running
#   ./force-iptables.sh --apply      Apply rules once (no daemon)
#   ./force-iptables.sh --check      Check rules once, exit with code
#
# Config:   /etc/kernel/force-iptables.rules  (iptables-restore format)
# Log:      /var/tmp/.log/force-iptables.log
# PID file: /var/run/force-iptables.pid
# Bypass lock: /var/tmp/force-iptables.bypass  (touch to pause enforcement)
#
set -e

# ─── Paths ───────────────────────────────────────────────────────────────────
RULES_FILE="/etc/kernel/force-iptables.rules"
LOG_DIR="/var/tmp/.log"
LOG_FILE="${LOG_DIR}/force-iptables.log"
PID_FILE="/var/run/force-iptables.pid"
BYPASS_LOCK="/var/tmp/force-iptables.bypass"
CHECK_INTERVAL=7  # seconds between checks (5-10 range)

# ─── Discord webhook (from funcs/discordNotif.sh pattern) ───────────────────
DISCORD_WEBHOOK=""
DISCORD_ENABLED=0  # Set to 1 to enable Discord notifications

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo -e "$msg"
}

log_alert() {
    log "ALERT: $1"
}

send_discord() {
    local title="$1"
    local desc="$2"
    local color="$3"  # hex color for embed (e.g. 15158332 = red)

    [ "$DISCORD_ENABLED" -eq 1 ] || return 0
    [ -n "$DISCORD_WEBHOOK" ] || return 0

    # Try to source the webhook from funcs/discordNotif.sh if not set
    if [ -z "$DISCORD_WEBHOOK" ] && [ -f "funcs/discordNotif.sh" ]; then
        DISCORD_WEBHOOK=$(grep '^webhook=' funcs/discordNotif.sh | head -1 | cut -d'"' -f2)
    fi
    [ -n "$DISCORD_WEBHOOK" ] || return 0

    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")

    curl -s -f -H "Content-Type: application/json" \
        -d "{
            \"embeds\":[{
                \"title\":\"${title}\",
                \"description\":\"${desc}\",
                \"color\":${color},
                \"fields\":[
                    {\"name\":\"Host\",\"value\":\"${hostname}\",\"inline\":true},
                    {\"name\":\"Time\",\"value\":\"$(date '+%Y-%m-%d %H:%M:%S')\",\"inline\":true}
                ],
                \"footer\":{\"text\":\"force-iptables daemon\"},
                \"timestamp\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"
            }]
        }" "$DISCORD_WEBHOOK" 2>/dev/null || true
}

# ─── Core logic ──────────────────────────────────────────────────────────────
get_current_rules() {
    iptables-save 2>/dev/null
}

rules_match() {
    local current
    current=$(get_current_rules)
    local desired
    desired=$(cat "$RULES_FILE" 2>/dev/null)

    [ -n "$current" ] && [ -n "$desired" ] || return 1

    # Normalize: sort both and compare (order of rules in save output
    # can vary slightly; sorting handles that)
    local cur_sorted des_sorted
    cur_sorted=$(echo "$current" | sort)
    des_sorted=$(echo "$desired" | sort)

    [ "$cur_sorted" = "$des_sorted" ]
}

apply_rules() {
    if [ ! -f "$RULES_FILE" ]; then
        log_alert "Rules file not found: $RULES_FILE"
        return 1
    fi

    iptables-restore < "$RULES_FILE" 2>/dev/null
    local rc=$?
    if [ $rc -ne 0 ]; then
        log_alert "iptables-restore failed (exit $rc). Rules file may be malformed."
        return 1
    fi
    return 0
}

check_and_enforce() {
    # ── Bypass lock check ──────────────────────────────────────────────
    # When /var/tmp/force-iptables.bypass exists, skip enforcement.
    # This lets admins temporarily disable iptables for package installs
    # (e.g. dnf/yum/apt that need to open ports for repos).
    if [ -f "$BYPASS_LOCK" ]; then
        log "SKIP: Bypass lock active ($BYPASS_LOCK). Enforcement paused."
        return 0
    fi

    # ── Config existence check ─────────────────────────────────────────
    if [ ! -f "$RULES_FILE" ]; then
        log_alert "Config file missing: $RULES_FILE — cannot enforce rules"
        return 1
    fi

    # ── Compare current vs desired ─────────────────────────────────────
    if rules_match; then
        return 0
    fi

    # ── Rules drifted — capture diff and re-apply ──────────────────────
    local current_rules desired_rules
    current_rules=$(get_current_rules)
    desired_rules=$(cat "$RULES_FILE")

    log_alert "RULES DRIFT DETECTED — iptables rules have been modified!"

    # Write diff to log
    {
        echo "=== DRIFT DETECTED AT $(date '+%Y-%m-%d %H:%M:%S') ==="
        echo "--- Current rules (before enforcement) ---"
        echo "$current_rules"
        echo ""
        echo "--- Diff (current vs desired) ---"
        diff <(echo "$current_rules" | sort) <(echo "$desired_rules" | sort) || true
        echo ""
        echo "=== Re-applying rules ==="
    } >> "$LOG_FILE"

    # ── Re-apply the correct rules ─────────────────────────────────────
    if apply_rules; then
        log "Rules re-applied successfully."
        send_discord "🔥 FIREWALL TAMPERING DETECTED" \
            "iptables rules were modified and have been forcibly restored on $(hostname 2>/dev/null || echo unknown)." \
            15158332  # Red
    else
        log_alert "FAILED to re-apply rules!"
        send_discord "⚠️ FIREWALL RESTORE FAILED" \
            "Attempted to restore iptables rules on $(hostname 2>/dev/null || echo unknown) but iptables-restore failed." \
            16737357  # Orange
    fi
}

# ─── Daemon loop ─────────────────────────────────────────────────────────────
run_daemon() {
    mkdir -p "$LOG_DIR"

    log "force-iptables daemon started (PID $$, interval ${CHECK_INTERVAL}s)"
    log "Rules file: $RULES_FILE"
    log "Bypass lock: $BYPASS_LOCK"

    # Write PID file
    echo $$ > "$PID_FILE"

    # Trap signals for clean shutdown
    trap 'log "Daemon stopped (signal received)."; rm -f "$PID_FILE"; exit 0' INT TERM

    while true; do
        check_and_enforce
        sleep "$CHECK_INTERVAL"
    done
}

# ─── Install as background daemon ────────────────────────────────────────────
install_daemon() {
    mkdir -p "$LOG_DIR"

    if daemon_running; then
        echo -e "${YELLOW}Daemon already running (PID $(cat "$PID_FILE" 2>/dev/null)).${NC}"
        return 1
    fi

    # Resolve script to absolute path
    local script_path
    script_path=$(readlink -f "$0")

    log "Installing daemon..."

    # Try systemd first, fall back to nohup
    if command -v systemctl >/dev/null 2>&1; then
        install_systemd "$script_path"
    else
        install_nohup "$script_path"
    fi
}

install_nohup() {
    local script_path="$1"
    nohup "$script_path" --daemon > /dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo -e "${GREEN}Daemon started in background (PID $pid) via nohup.${NC}"
    log "Daemon launched via nohup (PID $pid)"
}

install_systemd() {
    local script_path="$1"
    local service_name="force-iptables"
    local unit_file="/etc/systemd/system/${service_name}.service"

    cat > "$unit_file" <<EOF
[Unit]
Description=Force iptables rule enforcement daemon
After=network.target iptables.service
Wants=iptables.service

[Service]
Type=simple
ExecStart=${script_path} --daemon
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
LogsDirectory=force-iptables

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name" 2>/dev/null || true
    systemctl start "$service_name"

    # Wait briefly for PID file
    sleep 1

    if daemon_running; then
        echo -e "${GREEN}Daemon started via systemd (${service_name}).${NC}"
        log "Daemon launched via systemd"
    else
        echo -e "${YELLOW}systemd start may have failed. Falling back to nohup.${NC}"
        install_nohup "$script_path"
    fi
}

# ─── Stop daemon ─────────────────────────────────────────────────────────────
stop_daemon() {
    # Try systemd first
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active force-iptables >/dev/null 2>&1; then
        systemctl stop force-iptables
        echo -e "${GREEN}Daemon stopped via systemd.${NC}"
        log "Daemon stopped via systemd"
        return 0
    fi

    # Fall back to PID file
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            echo -e "${GREEN}Daemon stopped (PID $pid).${NC}"
            log "Daemon stopped (PID $pid)"
            return 0
        else
            echo -e "${YELLOW}PID file stale (PID $pid not running). Cleaning up.${NC}"
            rm -f "$PID_FILE"
            return 0
        fi
    fi

    echo -e "${YELLOW}Daemon not running (no PID file).${NC}"
    return 1
}

# ─── Status ──────────────────────────────────────────────────────────────────
status_daemon() {
    local running=0

    if daemon_running; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        echo -e "${GREEN}● Running${NC} (PID $pid)"
        running=1
    else
        echo -e "${RED}● Stopped${NC}"
        rm -f "$PID_FILE" 2>/dev/null
    fi

    # Check systemd status
    if command -v systemctl >/dev/null 2>&1; then
        local svc_status
        svc_status=$(systemctl is-active force-iptables 2>/dev/null || echo "not-installed")
        if [ "$svc_status" = "active" ]; then
            echo "  Systemd: active"
        elif [ "$svc_status" != "not-installed" ]; then
            echo "  Systemd: $svc_status"
        fi
    fi

    echo "  Rules file: $RULES_FILE $([ -f "$RULES_FILE" ] && echo '(exists)' || echo '(MISSING)')"
    echo "  Log file:   $LOG_FILE"
    echo "  Bypass lock: $BYPASS_LOCK $([ -f "$BYPASS_LOCK" ] && echo '(ACTIVE — enforcement paused)' || echo '(inactive)')"
    echo "  Check interval: ${CHECK_INTERVAL}s"

    return $((1 - running))
}

# ─── Check if daemon is running ──────────────────────────────────────────────
daemon_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

# ─── Generate default rules file ─────────────────────────────────────────────
generate_default_rules() {
    echo -e "${CYAN}Generating default rules file at $RULES_FILE${NC}"
    mkdir -p "$(dirname "$RULES_FILE")"

    # Generate iptables-restore compatible rules
    # These mirror the autofirewall.sh logic in iptables-restore format
    cat > "$RULES_FILE" <<'RULES'
# Generated by force-iptables.sh
# iptables-restore compatible format
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT DROP [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Established / related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow inbound TCP/UDP on common services (customize as needed)
# -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT
# -A INPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
# -A INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# Allow inbound ICMP
-A INPUT -p icmp -j ACCEPT

# Allow outbound DNS, NTP, HTTPS for package management
-A OUTPUT -p udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p udp --dport 123 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
-A OUTPUT -p tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT

# Vertical comms (internal network)
-A INPUT -s 192.168.111.0/24 -j ACCEPT
-A OUTPUT -d 192.168.111.0/24 -j ACCEPT

# Logging (rate limited)
-A INPUT -m limit --limit 5/min -j LOG --log-prefix "DROP_INPUT "
-A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "DROP_OUTPUT "

# Drop invalid packets early
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A OUTPUT -m conntrack --ctstate INVALID -j DROP

COMMIT
RULES

    chmod 600 "$RULES_FILE"
    echo -e "${GREEN}Default rules written to $RULES_FILE${NC}"
    echo "  Edit this file to customize allowed ports/services."
}

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
force-iptables.sh — Persistent iptables rule enforcement daemon

Usage:
  $0 --install          Start the daemon (systemd or nohup)
  $0 --stop             Stop the daemon
  $0 --status           Show daemon status
  $0 --apply            Apply rules once (no daemon)
  $0 --check            Check if rules match, exit 0=ok 1=drift
  $0 --generate-config  Generate default rules file
  $0 --daemon           Internal: run the daemon loop

Bypass mechanism:
  touch $BYPASS_LOCK     Pause enforcement (e.g. during package installs)
  rm $BYPASS_LOCK        Resume enforcement

Config: $RULES_FILE
Log:    $LOG_FILE
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --install)
        # Ensure rules file exists
        if [ ! -f "$RULES_FILE" ]; then
            echo -e "${YELLOW}Rules file not found. Generating default config...${NC}"
            generate_default_rules
        fi
        install_daemon
        ;;
    --stop)
        stop_daemon
        ;;
    --status)
        status_daemon
        ;;
    --apply)
        if [ ! -f "$RULES_FILE" ]; then
            echo "Error: Rules file not found: $RULES_FILE"
            echo "Run: $0 --generate-config"
            exit 1
        fi
        echo "Applying iptables rules from $RULES_FILE..."
        apply_rules && echo -e "${GREEN}Rules applied successfully.${NC}" || echo -e "${RED}Failed to apply rules.${NC}"
        ;;
    --check)
        if [ ! -f "$RULES_FILE" ]; then
            echo "Error: Rules file not found: $RULES_FILE"
            exit 1
        fi
        if rules_match; then
            echo -e "${GREEN}OK: iptables rules match desired state.${NC}"
            exit 0
        else
            echo -e "${RED}DRIFT: iptables rules differ from desired state.${NC}"
            diff <(get_current_rules | sort) <(cat "$RULES_FILE" | sort) || true
            exit 1
        fi
        ;;
    --generate-config)
        generate_default_rules
        ;;
    --daemon)
        run_daemon
        ;;
    --help|-h)
        usage
        ;;
    "")
        usage
        exit 1
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac
