#!/bin/sh
# install-manager.sh — install the CCDC Falco decoder/rules on the Wazuh manager.
#
# Run on the manager host (LXC 218 `siem`) as root, from the unpacked edr dir:
#   ./edr/wazuh/manager/install-manager.sh [container-name]
#
# Makes the agent-shipped Falco JSON (/var/log/falco/events.json) produce real
# Wazuh alerts instead of unmatched log entries. Validates the configuration
# before restarting and rolls the rule file back if analysisd rejects it.

set -eu

CONTAINER=${1:-single-node-wazuh.manager-1}
HERE=$(cd "$(dirname "$0")" && pwd)
RULES="$HERE/ccdc-falco.xml"

[ -r "$RULES" ] || { printf 'missing %s\n' "$RULES" >&2; exit 1; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    printf 'container %s not found\n' "$CONTAINER" >&2
    exit 1
fi

docker cp "$RULES" "$CONTAINER:/tmp/ccdc-falco.xml"
docker exec "$CONTAINER" sh -c "mv /tmp/ccdc-falco.xml /var/ossec/etc/rules/ccdc-falco.xml && chown wazuh:wazuh /var/ossec/etc/rules/ccdc-falco.xml && chmod 0660 /var/ossec/etc/rules/ccdc-falco.xml"

printf 'validating manager configuration...\n'
docker exec "$CONTAINER" /var/ossec/bin/wazuh-analysisd -t > /tmp/ccdc-falco-test.log 2>&1 || true
if grep -qE 'ERROR|CRITICAL' /tmp/ccdc-falco-test.log; then
    printf 'configuration test failed — removing ccdc-falco.xml and not restarting\n' >&2
    sed -n '1,20p' /tmp/ccdc-falco-test.log >&2
    docker exec "$CONTAINER" rm -f /var/ossec/etc/rules/ccdc-falco.xml
    exit 1
fi

printf 'restarting manager...\n'
docker restart "$CONTAINER" >/dev/null

for _ in $(seq 1 30); do
    sleep 2
    if docker exec "$CONTAINER" /var/ossec/bin/wazuh-control status 2>/dev/null | grep -q 'wazuh-remoted is running'; then
        printf 'manager restarted with CCDC Falco rules\n'
        exit 0
    fi
done

printf 'manager did not come back within 60s — check docker logs %s\n' "$CONTAINER" >&2
exit 1
