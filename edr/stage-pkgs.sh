#!/bin/sh
# stage-pkgs.sh — pre-round package staging for edr/deploy-edr.sh.
#
# Run this on a CONNECTED machine (before the round) to populate edr/pkg with
# the Falco + Wazuh agent packages, so the competition deploy never needs
# internet. x86_64 only (the CCDC images are amd64).
#
# Usage: ./edr/stage-pkgs.sh [deb|rpm|all]

set -eu

FALCO_VERSION=${FALCO_VERSION:-0.44.1}
WAZUH_VERSION=${WAZUH_VERSION:-4.14.10-1}

EDR_DIR=$(cd "$(dirname "$0")" && pwd)
DEST=$EDR_DIR/pkg
mkdir -p "$DEST"

fetch() {
    printf '  -> %s\n' "$2"
    curl -fL --retry 3 --connect-timeout 15 -o "$DEST/$2" "$1"
}

stage_deb() {
    printf 'Staging DEB packages (falco %s, wazuh-agent %s)\n' "$FALCO_VERSION" "$WAZUH_VERSION"
    fetch "https://download.falco.org/packages/deb/stable/falco-${FALCO_VERSION}-x86_64.deb" \
          "falco_${FALCO_VERSION}_amd64.deb"
    fetch "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_${WAZUH_VERSION}_amd64.deb" \
          "wazuh-agent_${WAZUH_VERSION}_amd64.deb"
}

stage_rpm() {
    printf 'Staging RPM packages (falco %s, wazuh-agent %s)\n' "$FALCO_VERSION" "$WAZUH_VERSION"
    fetch "https://download.falco.org/packages/rpm/falco-${FALCO_VERSION}-x86_64.rpm" \
          "falco-${FALCO_VERSION}-x86_64.rpm"
    fetch "https://packages.wazuh.com/4.x/yum/wazuh-agent-${WAZUH_VERSION}.x86_64.rpm" \
          "wazuh-agent-${WAZUH_VERSION}.x86_64.rpm"
}

case "${1:-all}" in
    deb) stage_deb ;;
    rpm) stage_rpm ;;
    all) stage_deb; stage_rpm ;;
    *)   printf 'usage: %s [deb|rpm|all]\n' "$0" >&2; exit 2 ;;
esac

printf '\nStaged %s\n' "$DEST"
sha256sum "$DEST"/* 2>/dev/null || true
printf 'NOTE: edr/pkg/ is gitignored — copy it into the deploy bundle (or scp it\n'
printf '      to each target) before the round. See edr/README.md.\n'
