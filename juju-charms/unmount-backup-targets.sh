#!/bin/bash -x
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
    for unit in $(juju status --format=json | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
units = []
for app in d['applications'].values():
    for u in app.get('units', {}).values():
        for sub in u.get('subordinates', {}).keys():
            if sub.startswith('trilio-data-mover/'):
                units.append(sub)
print('\n'.join(units))
"); do
        echo "  Running on ${unit} ..."
        juju run-action --wait "${unit}" unmount-old-backup-targets
    done
fi

echo ""
echo "=== Verifying no stale mounts remain ==="
FAILED=0
set +e

if [ "${JUJU_MAJOR}" -ge 3 ]; then
    WLM_MOUNTS=$(juju exec --application trilio-wlm 'findmnt | grep triliovault-mounts || true')
    DM_MOUNTS=$(juju exec --application trilio-data-mover 'findmnt | grep triliovault-mounts || true')
else
    WLM_MOUNTS=$(juju run --application trilio-wlm 'findmnt | grep triliovault-mounts || true')
    DM_MOUNTS=$(juju run --application trilio-data-mover 'findmnt | grep triliovault-mounts || true')
fi

if echo "$WLM_MOUNTS" | grep -q 'triliovault-mounts'; then
    echo "WARNING: Stale mounts found on trilio-wlm units:"
    echo "$WLM_MOUNTS"
    FAILED=1
else
    echo "trilio-wlm: all units clean"
fi

if echo "$DM_MOUNTS" | grep -q 'triliovault-mounts'; then
    echo "WARNING: Stale mounts found on trilio-data-mover units:"
    echo "$DM_MOUNTS"
    FAILED=1
else
    echo "trilio-data-mover: all units clean"
fi

echo ""
if [ "${FAILED}" -eq 1 ]; then
    echo "FAILED: Stale mounts remain on one or more units."
    echo "Review the output above and manually investigate the affected"
    echo "units before proceeding to create new backup targets."
    exit 1
fi

echo "SUCCESS: All units are clean. Proceed to create backup targets (Step 6)."
