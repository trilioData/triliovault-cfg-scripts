#!/bin/bash
# Unmount old backup targets on all trilio-wlm and trilio-data-mover units.
# Detects Juju client version and uses the appropriate command syntax.
# Run this script from a node where the juju client is installed and
# has access to the Juju controller.

set -e

JUJU_MAJOR=$(juju version 2>/dev/null | cut -d. -f1)

if [ -z "$JUJU_MAJOR" ]; then
    echo "ERROR: juju command not found or not accessible"
    exit 1
fi

echo "Detected Juju major version: ${JUJU_MAJOR}"
echo ""

if [ "${JUJU_MAJOR}" -ge 3 ]; then
    echo "=== Unmounting on trilio-wlm units ==="
    juju run trilio-wlm/* unmount-old-backup-targets

    echo ""
    echo "=== Unmounting on trilio-data-mover units ==="
    juju run trilio-data-mover/* unmount-old-backup-targets
else
    echo "=== Unmounting on trilio-wlm units ==="
    for unit in $(juju status trilio-wlm --format=json | \
      python3 -c "import sys,json; [print(u) for u in json.load(sys.stdin)['applications']['trilio-wlm']['units']]"); do
        echo "  Running on ${unit} ..."
        juju run-action --wait "${unit}" unmount-old-backup-targets
    done

    echo ""
    echo "=== Unmounting on trilio-data-mover units ==="
    for unit in $(juju status trilio-data-mover --format=json | \
      python3 -c "import sys,json; [print(u) for u in json.load(sys.stdin)['applications']['trilio-data-mover']['units']]"); do
        echo "  Running on ${unit} ..."
        juju run-action --wait "${unit}" unmount-old-backup-targets
    done
fi

echo ""
echo "=== Done. Verify no stale mounts remain ==="
if [ "${JUJU_MAJOR}" -ge 3 ]; then
    juju exec --application trilio-wlm 'findmnt | grep triliovault || echo "No stale mounts"'
    juju exec --application trilio-data-mover 'findmnt | grep triliovault || echo "No stale mounts"'
else
    juju run --application trilio-wlm 'findmnt | grep triliovault || echo "No stale mounts"'
    juju run --application trilio-data-mover 'findmnt | grep triliovault || echo "No stale mounts"'
fi
