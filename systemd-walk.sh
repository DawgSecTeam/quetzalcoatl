#!/bin/sh
# systemd-walk.sh — Interactive systemd service auditor (Card 74)
#
# Walks all running and enabled systemd services, shows unit file contents,
# and prompts the operator to Keep, Disable, Remove, or Skip each one.
# All actions are logged to /var/tmp/.log/systemd-walk.log.
#
# Usage:
#   ./systemd-walk.sh                    # interactive mode
#   ./systemd-walk.sh --non-interactive  # read decisions from config file
#
# Config file format (one per line):  SERVICE_NAME:ACTION
#   Actions: Y (keep), N (disable), R (remove), S (skip)
#   Example: /etc/systemd-walk.conf
#     sshd.service:Y
#     bluetooth.service:N
#     cups.service:R
#     unknown.service:S

# ── ANSI color setup ──────────────────────────────────────────────
C="$(printf '\033')"
RED="${C}[1;31m"
GREEN="${C}[1;32m"
YELLOW="${C}[1;33m"
BLUE="${C}[1;34m"
LIGHT_CYAN="${C}[1;96m"
LG="${C}[1;37m"
DG="${C}[1;90m"
NC="${C}[0m"

# ── Paths ─────────────────────────────────────────────────────────
LOG_DIR="/var/tmp/.log"
LOG_FILE="$LOG_DIR/systemd-walk.log"
CONFIG_FILE="${CONFIG_FILE:-/etc/systemd-walk.conf}"

# ── Counts ────────────────────────────────────────────────────────
COUNT_KEEP=0
COUNT_DISABLE=0
COUNT_REMOVE=0
COUNT_SKIP=0
COUNT_ERROR=0

# ── Root check ────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    printf "${RED}[ERROR]${NC} This script requires root privileges.\n"
    exit 1
fi

# ── Logging ───────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG_FILE"
}

# ── Header ────────────────────────────────────────────────────────
header() {
    printf "\n${BLUE}╔══════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║${NC} ${LIGHT_CYAN}%-48s${NC} ${BLUE}║${NC}\n" "$1"
    printf "${BLUE}╚══════════════════════════════════════════════════╝${NC}\n"
}

subheader() {
    printf "\n${DG}── ${LG}%s${DG} ──────────────────────────────────────────────${NC}\n" "$1"
}

# ── Detect init system ────────────────────────────────────────────
is_systemd() {
    [ -d /run/systemd/system ] && return 0
    command -v systemctl > /dev/null 2>&1 && return 0
    return 1
}

is_openrc() {
    command -v rc-status > /dev/null 2>&1 && return 0
    return 1
}

# ── Gather services ───────────────────────────────────────────────
# Returns a deduplicated, sorted list of service unit names.
gather_services() {
    running=""
    enabled=""

    if is_systemd; then
        # Get running services
        running=$(systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
            | awk '{print $1}' | sort)
        # Get enabled services (not currently running)
        enabled=$(systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null \
            | awk '{print $1}' | sort)
    fi

    # Combine and deduplicate
    printf "%s\n%s\n" "$running" "$enabled" | grep -v '^$' | sort -u
}

# ── Get unit file path ────────────────────────────────────────────
get_unit_file() {
    local svc="$1"
    svc="$1"
    # Check common systemd unit file locations
    for dir in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        if [ -f "$dir/$svc" ]; then
            printf "%s" "$dir/$svc"
            return 0
        fi
    done
    # Try systemctl to find the unit
    unit_path=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
    if [ -n "$unit_path" ] && [ -f "$unit_path" ]; then
        printf "%s" "$unit_path"
        return 0
    fi
    return 1
}

# ── Show unit file contents ───────────────────────────────────────
show_unit_file() {
    local svc="$1"
    svc="$1"
    unit_path=$(get_unit_file "$svc")

    if [ -n "$unit_path" ]; then
        subheader "Unit file: $unit_path"
        cat "$unit_path" 2>/dev/null | head -80
        # Check if file is longer than 80 lines
        line_count=$(wc -l < "$unit_path" 2>/dev/null)
        if [ "$line_count" -gt 80 ]; then
            printf "${DG}... (%s lines total, showing first 80)${NC}\n" "$line_count"
        fi
    else
        printf "${YELLOW}[WARN]${NC} No unit file found for %s\n" "$svc"
    fi
}

# ── Show service status ───────────────────────────────────────────
show_service_status() {
    local svc="$1"
    svc="$1"

    if is_systemd; then
        state=$(systemctl is-active "$svc" 2>/dev/null)
        enabled_state=$(systemctl is-enabled "$svc" 2>/dev/null)

        case "$state" in
            active)   printf "  State: ${GREEN}running${NC}" ;;
            inactive) printf "  State: ${DG}stopped${NC}" ;;
            failed)   printf "  State: ${RED}failed${NC}" ;;
            *)        printf "  State: ${YELLOW}%s${NC}" "$state" ;;
        esac

        case "$enabled_state" in
            enabled)     printf " | ${GREEN}enabled${NC}" ;;
            disabled)    printf " | ${DG}disabled${NC}" ;;
            static)      printf " | ${YELLOW}static${NC}" ;;
            masked)      printf " | ${RED}masked${NC}" ;;
            *)           printf " | ${YELLOW}%s${NC}" "$enabled_state" ;;
        esac
        printf "\n"
    fi
}

# ── Action: Disable service ───────────────────────────────────────
action_disable() {
    local svc="$1"
    svc="$1"
    log "DISABLE: $svc"
    printf "  ${YELLOW}Disabling${NC} %s ... " "$svc"
    if systemctl disable "$svc" 2>>"$LOG_FILE"; then
        printf "${GREEN}[OK]${NC}\n"
        COUNT_DISABLE=$((COUNT_DISABLE + 1))
    else
        printf "${RED}[FAILED]${NC}\n"
        log "  ERROR: Failed to disable $svc"
        COUNT_ERROR=$((COUNT_ERROR + 1))
    fi
}

# ── Action: Remove service ────────────────────────────────────────
action_remove() {
    svc="$1"
    unit_path=""
    log "REMOVE: $svc"
    printf "  ${RED}Stopping${NC} %s ... " "$svc"
    if systemctl stop "$svc" 2>>"$LOG_FILE"; then
        printf "${GREEN}[OK]${NC}\n"
    else
        printf "${YELLOW}[WARN]${NC} (may already be stopped)\n"
    fi

    # Disable the service
    printf "  ${YELLOW}Disabling${NC} %s ... " "$svc"
    if systemctl disable "$svc" 2>>"$LOG_FILE"; then
        printf "${GREEN}[OK]${NC}\n"
    else
        printf "${YELLOW}[WARN]${NC}\n"
    fi

    # Mask to prevent re-enable
    printf "  ${YELLOW}Masking${NC} %s ... " "$svc"
    if systemctl mask "$svc" 2>>"$LOG_FILE"; then
        printf "${GREEN}[OK]${NC}\n"
        log "  Masked $svc"
    else
        printf "${YELLOW}[WARN]${NC}\n"
    fi

    # Remove unit file if it exists and is not in /usr/lib (managed by packages)
    unit_path=$(get_unit_file "$svc")
    if [ -n "$unit_path" ]; then
        case "$unit_path" in
            /etc/systemd/system/*)
                printf "  ${RED}Removing${NC} unit file %s ... " "$unit_path"
                if rm -f "$unit_path" 2>>"$LOG_FILE"; then
                    printf "${GREEN}[OK]${NC}\n"
                    log "  Removed unit file: $unit_path"
                else
                    printf "${RED}[FAILED]${NC}\n"
                    log "  ERROR: Failed to remove $unit_path"
                    COUNT_ERROR=$((COUNT_ERROR + 1))
                fi
                systemctl daemon-reload 2>>"$LOG_FILE"
                ;;
            /usr/lib/systemd/system/*|/lib/systemd/system/*)
                printf "  ${DG}[SKIPPED]${NC} Unit file in package-managed path: %s\n" "$unit_path"
                log "  SKIPPED removal of package-managed unit: $unit_path"
                ;;
            *)
                printf "  ${YELLOW}[INFO]${NC} Unit file at: %s (manual review needed)\n" "$unit_path"
                log "  Unit file location for manual review: $unit_path"
                ;;
        esac
    fi

    COUNT_REMOVE=$((COUNT_REMOVE + 1))
}

# ── Interactive prompt ────────────────────────────────────────────
prompt_action() {
    local svc="$1"
    svc="$1"
    reply=""
    printf "\n${LIGHT_CYAN}  >>> %s${NC}\n" "$svc"
    show_service_status "$svc"
    show_unit_file "$svc"

    printf "\n  ${LG}Keep [Y], Disable [N], Remove [R], Skip [S]?${NC} "
    read -r reply

    case "$reply" in
        y|Y)
            printf "  ${GREEN}Keeping${NC} %s\n" "$svc"
            log "KEEP: $svc"
            COUNT_KEEP=$((COUNT_KEEP + 1))
            ;;
        n|N)
            action_disable "$svc"
            ;;
        r|R)
            action_remove "$svc"
            ;;
        s|S)
            printf "  ${DG}Skipping${NC} %s\n" "$svc"
            log "SKIP: $svc"
            COUNT_SKIP=$((COUNT_SKIP + 1))
            ;;
        *)
            printf "  ${YELLOW}Invalid input, skipping${NC} %s\n" "$svc"
            log "SKIP (invalid input): $svc"
            COUNT_SKIP=$((COUNT_SKIP + 1))
            ;;
    esac
}

# ── Non-interactive mode ──────────────────────────────────────────
run_non_interactive() {
    header "SYSTEMD SERVICE WALKER — Non-interactive mode"
    log "=== Non-interactive mode started ==="
    log "Config file: $CONFIG_FILE"

    if [ ! -f "$CONFIG_FILE" ]; then
        printf "${RED}[ERROR]${NC} Config file not found: $CONFIG_FILE\n"
        log "ERROR: Config file not found: $CONFIG_FILE"
        printf "\n  Expected format (one per line): SERVICE_NAME:ACTION\n"
        printf "  Actions: Y (keep), N (disable), R (remove), S (skip)\n"
        printf "  Example:\n"
        printf "    sshd.service:Y\n"
        printf "    bluetooth.service:N\n"
        printf "    cups.service:R\n"
        exit 1
    fi

    # Read config and apply decisions
    while IFS=: read -r svc action || [ -n "$svc" ]; do
        # Skip empty lines and comments
        case "$svc" in
            ""|'#'*) continue ;;
        esac

        # Trim whitespace
        svc=$(printf "%s" "$svc" | tr -d '[:space:]')
        action=$(printf "%s" "$action" | tr -d '[:space:]')

        [ -z "$svc" ] && continue

        case "$action" in
            y|Y)
                printf "  ${GREEN}Keeping${NC} %s\n" "$svc"
                log "KEEP: $svc"
                COUNT_KEEP=$((COUNT_KEEP + 1))
                ;;
            n|N)
                action_disable "$svc"
                ;;
            r|R)
                action_remove "$svc"
                ;;
            s|S)
                printf "  ${DG}Skipping${NC} %s\n" "$svc"
                log "SKIP: $svc"
                COUNT_SKIP=$((COUNT_SKIP + 1))
                ;;
            *)
                printf "  ${YELLOW}Unknown action '%s' for %s, skipping${NC}\n" "$action" "$svc"
                log "SKIP (unknown action '$action'): $svc"
                COUNT_SKIP=$((COUNT_SKIP + 1))
                ;;
        esac
    done < "$CONFIG_FILE"

    log "=== Non-interactive mode completed ==="
}

# ── Interactive mode ──────────────────────────────────────────────
run_interactive() {
    header "SYSTEMD SERVICE WALKER — Interactive mode"
    log "=== Interactive mode started ==="

    # Gather all services
    SERVICES=$(gather_services)

    if [ -z "$SERVICES" ]; then
        printf "${YELLOW}[WARN]${NC} No services found.\n"
        log "No services found"
        return
    fi

    TOTAL=$(printf "%s\n" "$SERVICES" | wc -l)
    printf "\n${LG}Found %s services to review.${NC}\n" "$TOTAL"
    log "Found $TOTAL services to review"

    printf "\n${DG}Service list:${NC}\n"
    printf "%s\n" "$SERVICES" | while read -r svc; do
        printf "  - %s\n" "$svc"
    done

    printf "\n${YELLOW}Press Enter to begin reviewing services...${NC} "
    read -r

    _svc_list=$(mktemp)
    printf "%s\n" "$SERVICES" > "$_svc_list"
    while IFS= read -r svc; do
        prompt_action "$svc"
        printf "\n${DG}────────────────────────────────────────────────────${NC}\n"
    done < "$_svc_list"
    rm -f "$_svc_list"

    log "=== Interactive mode completed ==="
}

# ── Summary ───────────────────────────────────────────────────────
print_summary() {
    header "ACTIONS SUMMARY"
    printf "\n"
    printf "  ${GREEN}Kept:${NC}    %s\n" "$COUNT_KEEP"
    printf "  ${YELLOW}Disabled:${NC} %s\n" "$COUNT_DISABLE"
    printf "  ${RED}Removed:${NC}  %s\n" "$COUNT_REMOVE"
    printf "  ${DG}Skipped:${NC}  %s\n" "$COUNT_SKIP"
    if [ "$COUNT_ERROR" -gt 0 ]; then
        printf "  ${RED}Errors:${NC}   %s\n" "$COUNT_ERROR"
    fi
    printf "\n"
    printf "  Log: ${LIGHT_CYAN}%s${NC}\n" "$LOG_FILE"
    printf "\n"
}

# ── OpenRC support (stub) ─────────────────────────────────────────
# ───────────────────────────────────────────────────────────────────
# TODO: Add OpenRC support for non-systemd systems (e.g., Alpine Linux)
#
# OpenRC uses rc-services instead of systemd units.
# Key commands:
#   rc-status              — list running services
#   rc-update show         — list services by runlevel (enabled)
#   rc-service <name> stop — stop a service
#   rc-update del <name> <runlevel> — disable a service from a runlevel
#   rc-service <name> start — start a service
#   rc-update add <name> <runlevel> — enable a service in a runlevel
#
# Unit file equivalent: /etc/init.d/<service_name> (init scripts)
# Config files: /etc/conf.d/<service_name>
#
# Implementation plan:
#   1. Detect OpenRC via: [ -d /run/openrc ] || command -v rc-status
#   2. gather_services_openrc():
#        - rc-status --all --nocolor | awk to extract service names
#        - rc-update show | awk to get enabled services per runlevel
#   3. show_unit_file_openrc():
#        - cat /etc/init.d/<service> (the init script itself)
#        - show /etc/conf.d/<service> if it exists
#   4. action_disable_openrc():
#        - rc-update del <service> default (and other runlevels)
#   5. action_remove_openrc():
#        - rc-service <service> stop
#        - rc-update del <service> default
#        - Optionally remove /etc/init.d/<service> if not package-managed
#   6. Integrate into main flow with is_openrc() detection
# ───────────────────────────────────────────────────────────────────

# ── Main ──────────────────────────────────────────────────────────
main() {
    # Parse arguments
    case "$1" in
        --non-interactive|-n)
            if ! is_systemd; then
                if is_openrc; then
                    printf "${YELLOW}[WARN]${NC} OpenRC detected — systemd walker not applicable.\n"
                    printf "  OpenRC support is not yet implemented (stub pending).\n"
                    log "OpenRC detected, systemd walker not applicable"
                else
                    printf "${RED}[ERROR]${NC} Neither systemd nor OpenRC detected.\n"
                    log "No supported init system found"
                fi
                exit 1
            fi
            run_non_interactive
            ;;
        --help|-h)
            printf "\n${LIGHT_CYAN}systemd-walk.sh${NC} — Interactive systemd service auditor\n\n"
            printf "Usage:\n"
            printf "  %s                    Run in interactive mode\n" "./systemd-walk.sh"
            printf "  %s --non-interactive  Read decisions from config file\n" "./systemd-walk.sh"
            printf "  %s --help             Show this help\n" "./systemd-walk.sh"
            printf "\nEnvironment:\n"
            printf "  CONFIG_FILE           Path to config file (default: /etc/systemd-walk.conf)\n"
            printf "\nConfig file format:\n"
            printf "  SERVICE_NAME:ACTION   (one per line)\n"
            printf "  Actions: Y (keep), N (disable), R (remove), S (skip)\n"
            printf "  Lines starting with # are comments\n"
            printf "\nActions:\n"
            printf "  Y — Keep service as-is\n"
            printf "  N — Disable service (stop on next boot)\n"
            printf "  R — Stop, disable, mask, and remove unit file (if in /etc)\n"
            printf "  S — Skip this service without changes\n"
            printf "\nLogging:\n"
            printf "  All actions logged to: %s\n" "$LOG_FILE"
            printf "\n"
            exit 0
            ;;
        "")
            if ! is_systemd; then
                if is_openrc; then
                    printf "${YELLOW}[WARN]${NC} OpenRC detected — systemd walker not applicable.\n"
                    printf "  OpenRC support is not yet implemented (stub pending).\n"
                    log "OpenRC detected, systemd walker not applicable"
                else
                    printf "${RED}[ERROR]${NC} Neither systemd nor OpenRC detected.\n"
                    log "No supported init system found"
                fi
                exit 1
            fi
            run_interactive
            ;;
        *)
            printf "${RED}[ERROR]${NC} Unknown argument: $1\n"
            printf "Use --help for usage information.\n"
            exit 1
            ;;
    esac

    print_summary
}

main "$@"
