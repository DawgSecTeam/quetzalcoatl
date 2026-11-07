#!/bin/sh
# deploy-edr.sh — deploy host EDR: Falco runtime detection + Wazuh log forwarder.
#
# Runs from /var/tmp/edr/ (unpacked by minzero/deploy.sh) or directly from a
# checkout. Idempotent, and fail-soft: a broken EDR deploy logs loudly and
# returns non-zero, but never takes a scored service down with it.
#
# Environment:
#   EDR_WAZUH_MANAGER   Wazuh manager address     (default 10.0.0.218)
#   EDR_PKG_DIR         offline package directory  (default <this dir>/pkg)
#   EDR_ALLOW_NETWORK   1 = fall back to vendor repos when no local package
#                       (default 0: competition-safe, no surprise internet use)
#   EDR_SKIP_FALCO      1 = skip Falco
#   EDR_SKIP_WAZUH      1 = skip Wazuh forwarder
#
# Exit codes: 0 all requested components up, 1 one or more components failed.

set -u

EDR_DIR=$(cd "$(dirname "$0")" && pwd)
MANAGER=${EDR_WAZUH_MANAGER:-10.0.0.218}
PKG_DIR=${EDR_PKG_DIR:-$EDR_DIR/pkg}
ALLOW_NET=${EDR_ALLOW_NETWORK:-0}
LOG_DIR=/var/tmp/.log
LOG=$LOG_DIR/edr.log
FAILED=0

mkdir -p "$LOG_DIR" 2>/dev/null || true

log()  { printf '[EDR] %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '[EDR][WARN] %s\n' "$*" | tee -a "$LOG" >&2; }
fail() { FAILED=1; printf '[EDR][FAIL] %s\n' "$*" | tee -a "$LOG" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    printf 'deploy-edr.sh must run as root\n' >&2
    exit 1
fi

FAMILY=unknown
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-} ${ID_LIKE:-}" in
        *alpine*)                          FAMILY=alpine ;;
        *debian*|*ubuntu*)                  FAMILY=deb ;;
        *rhel*|*fedora*|*centos*|*rocky*|*alma*|*amzn*) FAMILY=rpm ;;
    esac
fi
log "distro family: $FAMILY; manager: $MANAGER; pkg dir: $PKG_DIR"

find_pkg() {
    # $1 = glob, prints first match
    set -- $(find "$PKG_DIR" -maxdepth 2 -name "$1" 2>/dev/null | head -1)
    [ $# -gt 0 ] && printf '%s\n' "$1"
}

systemd_present() {
    command -v systemctl >/dev/null 2>&1
}

service_state() {
    # $1 = unit
    systemd_present && systemctl is-active --quiet "$1" 2>/dev/null
}

############################
# Falco
############################

install_falco() {
    [ "${EDR_SKIP_FALCO:-0}" = "1" ] && { log "falco: skipped by EDR_SKIP_FALCO"; return 0; }

    if command -v falco >/dev/null 2>&1; then
        log "falco: already installed ($(falco --version 2>/dev/null | head -1))"
        return 0
    fi

    case "$FAMILY" in
    deb)
        DEB=$(find_pkg 'falco_*_amd64.deb')
        if [ -n "${DEB:-}" ]; then
            log "falco: installing local package $DEB"
            FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                dpkg -i "$DEB" >>"$LOG" 2>&1 || apt-get -f install -y >>"$LOG" 2>&1
        elif [ "$ALLOW_NET" = "1" ]; then
            log "falco: installing from vendor apt repo"
            install -d -m 0755 /usr/share/keyrings
            curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
                | gpg --dearmor -o /usr/share/keyrings/falco-archive-keyring.gpg 2>>"$LOG" || true
            printf 'deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main\n' \
                > /etc/apt/sources.list.d/falcosecurity.list
            apt-get update >>"$LOG" 2>&1
            FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                apt-get install -y falco >>"$LOG" 2>&1
        else
            fail "falco: no local .deb in $PKG_DIR and EDR_ALLOW_NETWORK=0"
            return 1
        fi
        ;;
    rpm)
        RPM=$(find_pkg 'falco-*-x86_64.rpm')
        if [ -n "${RPM:-}" ]; then
            log "falco: installing local package $RPM"
            FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                dnf install -y "$RPM" >>"$LOG" 2>&1 || \
            FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                rpm -Uvh --replacepkgs "$RPM" >>"$LOG" 2>&1
        elif [ "$ALLOW_NET" = "1" ]; then
            log "falco: installing from vendor rpm repo"
            rpm --import https://falco.org/repo/falcosecurity-packages.asc >>"$LOG" 2>&1 || true
            curl -fsSL -o /etc/yum.repos.d/falcosecurity.repo https://falco.org/repo/falcosecurity-rpm.repo 2>>"$LOG"
            FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf \
                dnf install -y falco >>"$LOG" 2>&1
        else
            fail "falco: no local .rpm in $PKG_DIR and EDR_ALLOW_NETWORK=0"
            return 1
        fi
        ;;
    alpine)
        # No musl Falco package exists; Alpine boxes get the syslog forwarder only.
        warn "falco: not supported on Alpine (no musl package) — skipping"
        return 0
        ;;
    *)
        warn "falco: unknown distro family, skipping"
        return 0
        ;;
    esac

    if ! command -v falco >/dev/null 2>&1; then
        fail "falco: package install did not produce /usr/bin/falco"
        return 1
    fi
    log "falco: installed ($(falco --version 2>/dev/null | head -1))"
}

configure_falco() {
    [ "${EDR_SKIP_FALCO:-0}" = "1" ] && return 0
    [ -x /usr/bin/falco ] || return 0

    install -d -m 0755 /etc/falco/rules.d /var/log/falco
    if [ -f /etc/falco/falco.yaml ] && [ ! -f /etc/falco/falco.yaml.orig-edr ]; then
        cp -p /etc/falco/falco.yaml /etc/falco/falco.yaml.orig-edr
        log "falco: backed up packaged config to /etc/falco/falco.yaml.orig-edr"
    fi
    cmp -s "$EDR_DIR/falco/falco.yaml" /etc/falco/falco.yaml || \
        cp "$EDR_DIR/falco/falco.yaml" /etc/falco/falco.yaml
    cmp -s "$EDR_DIR/falco/ccdc-competition.yaml" /etc/falco/rules.d/ccdc-competition.yaml || \
        cp "$EDR_DIR/falco/ccdc-competition.yaml" /etc/falco/rules.d/ccdc-competition.yaml
    chmod 0644 /etc/falco/falco.yaml /etc/falco/rules.d/ccdc-competition.yaml

    if [ -f /etc/falco/falco_rules.yaml ]; then
        FALCO_VALIDATE_ARGS="--validate /etc/falco/falco_rules.yaml --validate /etc/falco/rules.d/ccdc-competition.yaml"
    else
        # No packaged stable rules: our rules depend on its macros, so don't try.
        warn "falco: /etc/falco/falco_rules.yaml missing — competition rules disabled"
        rm -f /etc/falco/rules.d/ccdc-competition.yaml
        FALCO_VALIDATE_ARGS=""
    fi

    if [ -n "$FALCO_VALIDATE_ARGS" ] && \
       ! falco -c /etc/falco/falco.yaml $FALCO_VALIDATE_ARGS >>"$LOG" 2>&1; then
        fail "falco: rule/config validation failed — reverting to packaged config"
        [ -f /etc/falco/falco.yaml.orig-edr ] && cp -p /etc/falco/falco.yaml.orig-edr /etc/falco/falco.yaml
        mv /etc/falco/rules.d/ccdc-competition.yaml /etc/falco/rules.d/ccdc-competition.yaml.invalid 2>/dev/null || true
        return 1
    fi
    log "falco: config + competition rules validate"
}

start_falco() {
    [ "${EDR_SKIP_FALCO:-0}" = "1" ] && return 0
    [ -x /usr/bin/falco ] || return 0
    systemd_present || { warn "falco: systemd absent, not starting"; return 0; }

    # No mid-round rule/driver pulls: falcoctl would phone the registry.
    systemctl mask falcoctl-artifact-follow.service >>"$LOG" 2>&1 || true

    if [ -f /usr/lib/systemd/system/falco-modern-bpf.service ] || \
       [ -f /lib/systemd/system/falco-modern-bpf.service ] || \
       [ -f /etc/systemd/system/falco-modern-bpf.service ]; then
        UNIT=falco-modern-bpf
    else
        UNIT=falco
    fi

    systemctl enable "$UNIT.service" >>"$LOG" 2>&1 || true
    systemctl restart "$UNIT.service" >>"$LOG" 2>&1 || true
    sleep 3
    if service_state "$UNIT"; then
        log "falco: $UNIT active"
        return 0
    fi

    # modern eBPF needs >=5.8 with BTF; fall back to the kmod driver once.
    warn "falco: $UNIT did not stay up — trying kmod fallback"
    systemctl stop "$UNIT.service" >>"$LOG" 2>&1 || true
    if [ -f /usr/lib/systemd/system/falco-kmod.service ] || [ -f /lib/systemd/system/falco-kmod.service ]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y dkms make kernel-devel-"$(uname -r)" >>"$LOG" 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get install -y dkms make "linux-headers-$(uname -r)" >>"$LOG" 2>&1 || true
        fi
        systemctl enable --now falco-kmod.service >>"$LOG" 2>&1 || true
        sleep 3
        if service_state falco-kmod; then
            log "falco: kmod driver active (modern eBPF unavailable on $(uname -r))"
            return 0
        fi
    fi
    fail "falco: no driver came up on kernel $(uname -r) — see journalctl -u $UNIT"
    return 1
}

############################
# Wazuh
############################

install_wazuh_agent() {
    [ "${EDR_SKIP_WAZUH:-0}" = "1" ] && { log "wazuh: skipped by EDR_SKIP_WAZUH"; return 1; }

    if command -v /var/ossec/bin/wazuh-control >/dev/null 2>&1; then
        log "wazuh: agent already installed"
        return 0
    fi

    case "$FAMILY" in
    deb)
        DEB=$(find_pkg 'wazuh-agent_*_amd64.deb')
        if [ -n "${DEB:-}" ]; then
            log "wazuh: installing local package $DEB"
            WAZUH_MANAGER="$MANAGER" dpkg -i "$DEB" >>"$LOG" 2>&1 || \
                { apt-get -f install -y >>"$LOG" 2>&1 && WAZUH_MANAGER="$MANAGER" dpkg -i "$DEB" >>"$LOG" 2>&1; }
        elif [ "$ALLOW_NET" = "1" ]; then
            log "wazuh: installing from vendor apt repo"
            curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
                | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg 2>>"$LOG" || true
            printf 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main\n' \
                > /etc/apt/sources.list.d/wazuh.list
            apt-get update >>"$LOG" 2>&1
            WAZUH_MANAGER="$MANAGER" apt-get install -y wazuh-agent >>"$LOG" 2>&1
        else
            fail "wazuh: no local .deb in $PKG_DIR and EDR_ALLOW_NETWORK=0"
            return 1
        fi
        ;;
    rpm)
        RPM=$(find_pkg 'wazuh-agent-*.x86_64.rpm')
        if [ -n "${RPM:-}" ]; then
            log "wazuh: installing local package $RPM"
            WAZUH_MANAGER="$MANAGER" dnf install -y "$RPM" >>"$LOG" 2>&1 || \
                WAZUH_MANAGER="$MANAGER" rpm -Uvh --replacepkgs "$RPM" >>"$LOG" 2>&1
        elif [ "$ALLOW_NET" = "1" ]; then
            log "wazuh: installing from vendor rpm repo"
            rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH >>"$LOG" 2>&1 || true
            printf '[wazuh]\nname=EL-%s - Wazuh\nbaseurl=https://packages.wazuh.com/4.x/yum/\ngpgcheck=1\ngpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH\nenabled=1\n' \
                "$(rpm -E %rhel 2>/dev/null || echo 9)" > /etc/yum.repos.d/wazuh.repo
            WAZUH_MANAGER="$MANAGER" dnf install -y wazuh-agent >>"$LOG" 2>&1
        else
            fail "wazuh: no local .rpm in $PKG_DIR and EDR_ALLOW_NETWORK=0"
            return 1
        fi
        ;;
    alpine)
        # No apk agent; the syslog fallback is the whole forwarder on Alpine.
        warn "wazuh: no Alpine agent package — syslog forwarder only"
        return 1
        ;;
    *)
        warn "wazuh: unknown distro family"
        return 1
        ;;
    esac

    if [ ! -x /var/ossec/bin/wazuh-control ]; then
        fail "wazuh: install did not produce /var/ossec/bin/wazuh-control"
        return 1
    fi
    log "wazuh: agent installed"
}

configure_wazuh_agent() {
    [ -x /var/ossec/bin/wazuh-control ] || return 0

    AUTHLOG=/var/log/auth.log
    SYSLOG=/var/log/syslog
    KERNLOG=/var/log/kern.log
    WEBLOG1=/var/log/apache2/access.log
    WEBLOG2=/var/log/nginx/access.log
    if [ "$FAMILY" = "rpm" ]; then
        AUTHLOG=/var/log/secure
        SYSLOG=/var/log/messages
        KERNLOG=/var/log/messages
        WEBLOG1=/var/log/httpd/access_log
    fi

    # Only declare web logs that exist: a missing localfile is a permanent
    # logcollector ERROR on every agent and pollutes competition triage.
    WEBLOGS=""
    for f in "$WEBLOG1" "$WEBLOG2"; do
        [ -f "$f" ] || continue
        WEBLOGS="$WEBLOGS  <localfile>
    <log_format>apache</log_format>
    <location>$f</location>
  </localfile>
"
    done

    sed -e "s|__MANAGER__|$MANAGER|g" \
        -e "s|__AUTHLOG__|$AUTHLOG|g" \
        -e "s|__SYSLOG__|$SYSLOG|g" \
        -e "s|__KERNLOG__|$KERNLOG|g" \
        "$EDR_DIR/wazuh/ossec-agent.conf.tmpl" \
        | awk -v web="$WEBLOGS" '{gsub(/__WEBLOGS__/, web)}1' > /var/ossec/etc/ossec.conf.new
    if ! cmp -s /var/ossec/etc/ossec.conf.new /var/ossec/etc/ossec.conf 2>/dev/null; then
        mv /var/ossec/etc/ossec.conf.new /var/ossec/etc/ossec.conf
        log "wazuh: agent config updated"
    else
        rm -f /var/ossec/etc/ossec.conf.new
    fi
    chmod 0640 /var/ossec/etc/ossec.conf
    chown root:wazuh /var/ossec/etc/ossec.conf 2>/dev/null || chown root:root /var/ossec/etc/ossec.conf
    log "wazuh: agent config points at $MANAGER"
}

enroll_wazuh_agent() {
    [ "${EDR_SKIP_WAZUH:-0}" = "1" ] && return 0
    [ -x /var/ossec/bin/agent-auth ] || return 0
    if [ -s /var/ossec/etc/client.keys ]; then
        log "wazuh: already enrolled ($(wc -l < /var/ossec/etc/client.keys) key(s))"
        return 0
    fi
    # Explicit -A name: competition boxes routinely share hostnames ("workshop"),
    # and a duplicate name is rejected by the manager's authd.
    H=$(hostname -s 2>/dev/null || hostname)
    IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -n "${IP:-}" ] && H="$H-${IP##*.}"
    NAME=${EDR_AGENT_NAME:-$H}
    NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '-')
    if /var/ossec/bin/agent-auth -m "$MANAGER" -A "$NAME" >>"$LOG" 2>&1; then
        log "wazuh: enrolled as $NAME"
    else
        warn "wazuh: explicit enrollment failed — start will retry via authd"
    fi
}

start_wazuh_agent() {
    [ -x /var/ossec/bin/wazuh-control ] || return 1
    if systemd_present; then
        systemctl enable wazuh-agent >>"$LOG" 2>&1 || true
        systemctl restart wazuh-agent >>"$LOG" 2>&1 || true
        sleep 3
        if service_state wazuh-agent; then
            log "wazuh: agent active"
            return 0
        fi
        fail "wazuh: agent did not start — see journalctl -u wazuh-agent"
        return 1
    fi
    /var/ossec/bin/wazuh-control start >>"$LOG" 2>&1 || true
    log "wazuh: started via wazuh-control (no systemd)"
}

############################
# Syslog fallback (no agent package: Alpine, or agent install failure)
############################

install_syslog_forward() {
    [ "${EDR_SKIP_WAZUH:-0}" = "1" ] && return 0
    [ -x /var/ossec/bin/wazuh-control ] && return 0

    case "$FAMILY" in
    alpine)
        if command -v rsyslogd >/dev/null 2>&1 || apk add rsyslog >>"$LOG" 2>&1; then
            install -d -m 0755 /etc/rsyslog.d
            sed "s|__MANAGER__|$MANAGER|g" "$EDR_DIR/wazuh/rsyslog-forward.conf" \
                > /etc/rsyslog.d/50-ccdc-forward.conf
            rc-update add rsyslog default >>"$LOG" 2>&1 || true
            rc-service rsyslog restart >>"$LOG" 2>&1 || true
            if rc-service rsyslog status >/dev/null 2>&1; then
                log "wazuh: rsyslog forwarder active -> $MANAGER:514/udp"
                return 0
            fi
        fi
        # busybox syslogd fallback, persisted through openrc local.d
        install -d -m 0755 /etc/local.d
        cat > /etc/local.d/ccdc-syslog-forward.start <<EOF
#!/bin/sh
# Ship syslog to the Wazuh manager (syslog input 514/udp)
pkill syslogd 2>/dev/null
syslogd -O /var/log/messages -R $MANAGER:514
EOF
        chmod +x /etc/local.d/ccdc-syslog-forward.start
        rc-update add local default >>"$LOG" 2>&1 || true
        /etc/local.d/ccdc-syslog-forward.start >>"$LOG" 2>&1 || true
        log "wazuh: busybox syslogd forwarder active -> $MANAGER:514/udp"
        ;;
    *)
        warn "wazuh: agent unavailable and no syslog fallback for $FAMILY"
        return 1
        ;;
    esac
}

############################
# Tamper watchdog (systemd only)
############################

install_watchdog() {
    systemd_present || return 0
    cmp -s "$EDR_DIR/watchdog.sh" /usr/local/sbin/edr-watchdog || \
        cp "$EDR_DIR/watchdog.sh" /usr/local/sbin/edr-watchdog
    chmod 0750 /usr/local/sbin/edr-watchdog
    install -d -m 0755 /etc/systemd/system
    cmp -s "$EDR_DIR/systemd/edr-watchdog.service" /etc/systemd/system/edr-watchdog.service || \
        cp "$EDR_DIR/systemd/edr-watchdog.service" /etc/systemd/system/edr-watchdog.service
    cmp -s "$EDR_DIR/systemd/edr-watchdog.timer" /etc/systemd/system/edr-watchdog.timer || \
        cp "$EDR_DIR/systemd/edr-watchdog.timer" /etc/systemd/system/edr-watchdog.timer
    systemctl daemon-reload >>"$LOG" 2>&1 || true
    systemctl enable --now edr-watchdog.timer >>"$LOG" 2>&1 || true
    log "watchdog: edr-watchdog.timer active"
}

############################
# Run
############################

install_falco
configure_falco
install_watchdog
start_falco

if install_wazuh_agent; then
    configure_wazuh_agent
    enroll_wazuh_agent
    start_wazuh_agent || FAILED=1
else
    install_syslog_forward || FAILED=1
fi

log "---- summary ----"
if command -v falco >/dev/null 2>&1; then
    command -v systemctl >/dev/null 2>&1 && log "falco active: $(service_state falco-modern-bpf && echo yes || echo no)"
    log "falco rules file loaded: $(falco --support 2>/dev/null | grep -c 'ccdc-competition') reference(s)"
fi
if [ -x /var/ossec/bin/wazuh-control ]; then
    log "wazuh agent: $(systemctl is-active wazuh-agent 2>/dev/null || echo unknown) -> $(grep -o '<address>[^<]*' /var/ossec/etc/ossec.conf | head -1 | cut -d'>' -f2)"
else
    log "wazuh forwarder: syslog-only -> $MANAGER:514/udp"
fi

[ "$FAILED" -eq 0 ] && log "EDR deploy complete" || warn "EDR deploy completed with failures (see $LOG)"
exit "$FAILED"
