#!/bin/sh
# edr-watchdog — restart EDR sensors if red kills them.
# Installed to /usr/local/sbin/edr-watchdog, run by edr-watchdog.timer every 60s.

LOG=/var/log/edr-watchdog.log
TS=$(date -u +%FT%TZ)

[ -w "$LOG" ] || LOG=/var/log/messages

restart_unit() {
    UNIT=$1
    if systemctl list-unit-files "$UNIT.service" >/dev/null 2>&1; then
        if ! systemctl is-active --quiet "$UNIT" 2>/dev/null; then
            printf '%s %s down — restarting\n' "$TS" "$UNIT" >> "$LOG"
            systemctl restart "$UNIT" >> "$LOG" 2>&1
            logger -t edr-watchdog "restarted $UNIT"
        fi
    fi
}

# Only report something that is *supposed* to be running: a unit left masked or
# disabled by the operator is not a tamper event.
if systemctl is-enabled falco-modern-bpf 2>/dev/null | grep -q '^enabled'; then
    restart_unit falco-modern-bpf
elif systemctl is-enabled falco 2>/dev/null | grep -q '^enabled'; then
    restart_unit falco
fi

if systemctl is-enabled wazuh-agent 2>/dev/null | grep -q '^enabled'; then
    restart_unit wazuh-agent
fi

exit 0
