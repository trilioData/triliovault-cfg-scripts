#!/bin/bash
# upgrade_backup_targets_62.sh
#
# Create-or-upgrade T4O 6.2 backup targets from a pre-6.2 overlay bundle YAML.
#
# Runs on the Juju controller node. All workloadmgr / openstack / trilio-dms-cli
# commands are executed remotely on the trilio-wlm unit via "juju ssh".
# Target unit: the leader unit with workload-status=active, or the first active
# unit found if the leader is not active.
#
# Existence check: backend endpoint (filesystem-export) must match an entry in
# workloadmgr backup-target-list.
#   EXISTS  — NFS: update --nfs-mount-opts only
#             S3:  create new Barbican secret, then update --secret-ref only
#   NOT EXISTS — full create (NFS direct; S3 via Barbican flow)
#
# Usage:
#   ./upgrade_backup_targets_62.sh -b <bundle.yaml> -r <openrc>
#
# Options:
#   -b  Pre-6.2 overlay bundle YAML (required)
#   -r  OpenRC file with OpenStack credentials (required)

set -uo pipefail

BUNDLE_FILE=""
OPENRC_FILE=""
WLM_APP="${WLM_APP:-trilio-wlm}"
ERRORS=0
REMOTE_OPENRC="/tmp/.trilio_upgrade_openrc"

usage() {
    echo "Usage: $0 -b <bundle.yaml> -r <openrc>"
    exit 1
}

while getopts "b:r:" opt; do
    case "$opt" in
        b) BUNDLE_FILE="$OPTARG" ;;
        r) OPENRC_FILE="$OPTARG" ;;
        *) usage ;;
    esac
done

[ -z "$BUNDLE_FILE" ] && { echo "ERROR: -b <bundle.yaml> is required"; usage; }
[ -z "$OPENRC_FILE" ] && { echo "ERROR: -r <openrc> is required"; usage; }
[ -f "$BUNDLE_FILE" ] || { echo "ERROR: bundle file not found: $BUNDLE_FILE"; exit 1; }
[ -f "$OPENRC_FILE" ] || { echo "ERROR: openrc file not found: $OPENRC_FILE"; exit 1; }

# ---------------------------------------------------------------------------
# Find active WLM unit (leader preferred, else first active unit)
# ---------------------------------------------------------------------------
echo "INFO: locating active $WLM_APP unit..."
WLM_UNIT=$(juju status "$WLM_APP" --format json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
units = d.get('applications',{}).get('$WLM_APP',{}).get('units',{})
# Leader with active workload status first
for name, info in units.items():
    ws = info.get('workload-status',{}).get('current','')
    if info.get('leader') and ws == 'active':
        print(name); sys.exit(0)
# Any active unit as fallback
for name, info in units.items():
    if info.get('workload-status',{}).get('current','') == 'active':
        print(name); sys.exit(0)
sys.exit(1)
" 2>/dev/null) || { echo "ERROR: no active $WLM_APP unit found"; exit 1; }

echo "INFO: using unit: $WLM_UNIT"

# ---------------------------------------------------------------------------
# Source openrc on the controller to resolve any command substitutions
# (e.g. OS_TOKEN=$(openstack token issue ...)), then write a clean literal
# rc file with only OS_* exports (no commands, no OS_CACERT) and copy it
# to the unit. Certs are already in the trusted path on the unit.
# ---------------------------------------------------------------------------
CLEAN_OPENRC=$(mktemp /tmp/trilio_openrc_clean_XXXXXX)

cleanup() {
    rm -f "$CLEAN_OPENRC"
    juju ssh --pty=false "$WLM_UNIT" "rm -f $REMOTE_OPENRC" 2>/dev/null || true
}
trap cleanup EXIT

echo "INFO: resolving openrc on controller..."
(
    # shellcheck disable=SC1090
    source "$OPENRC_FILE" 2>/dev/null
    while IFS='=' read -r var _; do
        [[ "$var" =~ ^OS_ ]] || continue
        [ "$var" = "OS_CACERT" ] && continue
        val="${!var:-}"
        printf 'export %s=%q\n' "$var" "$val"
    done < <(env | grep '^OS_')
) > "$CLEAN_OPENRC"

juju scp "$CLEAN_OPENRC" "${WLM_UNIT}:${REMOTE_OPENRC}"
echo "INFO: clean openrc (literal values, no OS_CACERT) copied to ${WLM_UNIT}:${REMOTE_OPENRC}"

# ---------------------------------------------------------------------------
# run_remote: execute a command on the unit with openrc sourced.
# Prints the command (masking passwords) and full output to the screen.
# ---------------------------------------------------------------------------
run_remote() {
    local cmd="$1"
    local safe_cmd
    safe_cmd=$(echo "$cmd" | sed -E \
        's/(--os-password[[:space:]]+)[^[:space:]]*/\1[MASKED]/g;
         s/(OS_PASSWORD=)[^[:space:]]*/\1[MASKED]/g;
         s/(--payload[[:space:]]+)[^[:space:]]*/\1[MASKED]/g;
         s/(--secret-key[[:space:]]+)[^[:space:]]*/\1[MASKED]/g;
         s/(--access-key[[:space:]]+)[^[:space:]]*/\1[MASKED]/g')
    echo ""
    echo "  >> $safe_cmd"
    juju ssh --pty=false "$WLM_UNIT" \
        "source $REMOTE_OPENRC 2>/dev/null; $cmd" 2>&1
}

# ---------------------------------------------------------------------------
# Parse bundle YAML → backup_targets JSON array (on controller)
# ---------------------------------------------------------------------------
BACKUP_TARGETS_JSON=$(python3 - "$BUNDLE_FILE" <<'PYEOF'
import sys, json, yaml
with open(sys.argv[1]) as f:
    bundle = yaml.safe_load(f)
apps = bundle.get('applications', {})
for app_name in ('trilio-wlm', 'trilio-data-mover'):
    opts = apps.get(app_name, {}).get('options', {})
    if 'trilio-backup-targets' in opts:
        raw = opts['trilio-backup-targets']
        data = json.loads(raw) if isinstance(raw, str) else raw
        print(json.dumps(data))
        sys.exit(0)
print('[]')
sys.exit(1)
PYEOF
)

BT_COUNT=$(echo "$BACKUP_TARGETS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$BT_COUNT" -eq 0 ]; then
    echo "ERROR: no backup targets found in $BUNDLE_FILE"
    exit 1
fi
echo "INFO: found $BT_COUNT backup target(s) in bundle"

# ---------------------------------------------------------------------------
# Get current backup-target-list from WLM
# ---------------------------------------------------------------------------
echo ""
echo "INFO: fetching existing backup targets from WLM..."
EXISTING_JSON=$(run_remote "workloadmgr backup-target-list --format json" | \
    python3 -c "
import sys
lines = sys.stdin.read()
# juju ssh may prepend SSH warning lines; extract the JSON array
import re
m = re.search(r'\[.*\]', lines, re.DOTALL)
print(m.group(0) if m else '[]')
")

# ---------------------------------------------------------------------------
# Process each backup target
# ---------------------------------------------------------------------------
IDX=0
while IFS= read -r BT_JSON; do
    BT_NAME=$(echo "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backup-target-name','unnamed'))")
    BT_TYPE=$(echo  "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backup-target-type','').lower())")

    echo ""
    echo "================================================================="
    echo "[$BT_NAME]  type=$BT_TYPE"
    echo "================================================================="

    # Compute filesystem-export (used as the existence-check key)
    if [ "$BT_TYPE" = "nfs" ]; then
        NFS_SHARES=$(echo "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('nfs-shares',''))")
        NFS_OPTIONS=$(echo "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('nfs-options','nolock,soft,timeo=180,intr,lookupcache=none'))")
        FS_EXPORT="$NFS_SHARES"

    elif [ "$BT_TYPE" = "s3" ]; then
        S3_BUCKET=$(echo    "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3-bucket',''))")
        S3_ENDPOINT=$(echo  "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3-endpoint-url',''))")
        S3_ACCESS=$(echo    "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3-access-key',''))")
        S3_SECRET=$(echo    "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3-secret-key',''))")
        S3_SSL=$(echo       "$BT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('s3-ssl-enabled') else 'false')")
        S3_SSL_VERIFY=$(echo "$BT_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('s3-ssl-verify') else 'false')")
        S3_CERT=$(echo      "$BT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3-ssl-ca_cert',''))")

        if [ -n "$S3_ENDPOINT" ]; then
            FS_EXPORT=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${S3_ENDPOINT}').hostname + '/${S3_BUCKET}')")
        else
            FS_EXPORT="$S3_BUCKET"
        fi
    else
        echo "SKIP: unsupported type '$BT_TYPE'"
        IDX=$((IDX + 1))
        continue
    fi

    echo "  filesystem-export (existence key): $FS_EXPORT"

    # Check if a matching backup target already exists in WLM
    EXISTING_ID=$(echo "$EXISTING_JSON" | python3 - "$FS_EXPORT" "$BT_TYPE" <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
fs_export, bt_type = sys.argv[1], sys.argv[2]
for t in data:
    if t.get('Type','').lower() == bt_type and fs_export in t.get('Backend Endpoint',''):
        print(t.get('ID',''))
        sys.exit(0)
print('')
PYEOF
    )

    [ "$IDX" -eq 0 ] && DEFAULT_FLAG="--default" || DEFAULT_FLAG=""

    # -----------------------------------------------------------------------
    # NFS
    # -----------------------------------------------------------------------
    if [ "$BT_TYPE" = "nfs" ]; then
        if [ -n "$EXISTING_ID" ]; then
            echo "  EXISTS (id=$EXISTING_ID) — updating nfs-mount-opts only"
            OUT=$(run_remote "workloadmgr backup-target-update $EXISTING_ID --nfs-mount-opts '$NFS_OPTIONS'")
            echo "$OUT"
            if echo "$OUT" | grep -qiE '^ERROR|^Error:'; then
                echo "  ERROR: update failed for $BT_NAME" >&2
                ERRORS=$((ERRORS + 1))
            else
                echo "  OK: updated $BT_NAME"
            fi
        else
            echo "  NOT FOUND — creating NFS backup target"
            CREATE_CMD="workloadmgr backup-target-create --btt-name '$BT_NAME' --type nfs --filesystem-export '$NFS_SHARES'"
            [ -n "$NFS_OPTIONS" ] && CREATE_CMD+=" --nfs-mount-opts '$NFS_OPTIONS'"
            [ -n "$DEFAULT_FLAG" ] && CREATE_CMD+=" $DEFAULT_FLAG"
            OUT=$(run_remote "$CREATE_CMD")
            echo "$OUT"
            if echo "$OUT" | grep -qiE '^ERROR|^Error:'; then
                echo "  ERROR: create failed for $BT_NAME" >&2
                ERRORS=$((ERRORS + 1))
            else
                echo "  OK: created $BT_NAME"
            fi
        fi

    # -----------------------------------------------------------------------
    # S3
    # -----------------------------------------------------------------------
    elif [ "$BT_TYPE" = "s3" ]; then
        REMOTE_SECRET_JSON="/tmp/trilio_dms_${BT_NAME}.json"
        REMOTE_CERT="/tmp/trilio_cert_${BT_NAME}.pem"

        # Write CA cert to unit if SSL verify is enabled
        if [ "$S3_SSL_VERIFY" = "true" ] && [ -n "$S3_CERT" ]; then
            echo "  Copying CA cert to unit..."
            echo "$S3_CERT" | juju ssh --pty=false "$WLM_UNIT" "cat > $REMOTE_CERT" 2>/dev/null
            SSL_VERIFY_FLAGS="--ssl-verify --ssl-cert $REMOTE_CERT"
        else
            SSL_VERIFY_FLAGS="--no-ssl-verify"
        fi

        [ "$S3_SSL" = "true" ] && SSL_FLAG="--ssl" || SSL_FLAG="--no-ssl"
        ENDPOINT_FLAG=""
        [ -n "$S3_ENDPOINT" ] && ENDPOINT_FLAG="--endpoint-url '$S3_ENDPOINT'"

        # Create DMS secret payload on the unit
        echo "  Creating DMS secret payload..."
        DMS_CMD="trilio-dms-cli secret-payload create"
        DMS_CMD+=" --access-key '$S3_ACCESS'"
        DMS_CMD+=" --secret-key '$S3_SECRET'"
        DMS_CMD+=" --bucket '$S3_BUCKET'"
        DMS_CMD+=" --filesystem-export '$FS_EXPORT'"
        DMS_CMD+=" -o $REMOTE_SECRET_JSON"
        DMS_CMD+=" $SSL_FLAG $SSL_VERIFY_FLAGS"
        [ -n "$ENDPOINT_FLAG" ] && DMS_CMD+=" $ENDPOINT_FLAG"

        OUT=$(run_remote "$DMS_CMD") && DMS_RC=0 || DMS_RC=$?
        echo "$OUT"
        if [ $DMS_RC -ne 0 ]; then
            echo "  ERROR: trilio-dms-cli failed for $BT_NAME" >&2
            juju ssh --pty=false "$WLM_UNIT" "rm -f $REMOTE_SECRET_JSON $REMOTE_CERT" 2>/dev/null || true
            ERRORS=$((ERRORS + 1))
            IDX=$((IDX + 1))
            continue
        fi

        # Store secret in Barbican
        echo "  Storing secret in Barbican..."
        STORE_CMD="openstack secret store --name 'secret-key-${BT_NAME}' --payload \"\$(cat $REMOTE_SECRET_JSON)\" -f json"
        STORE_OUT=$(run_remote "$STORE_CMD")
        echo "$STORE_OUT"

        # Clean up secret payload file from unit
        juju ssh --pty=false "$WLM_UNIT" "rm -f $REMOTE_SECRET_JSON $REMOTE_CERT" 2>/dev/null || true

        # Parse secret href from store output (strip any SSH banner lines)
        SECRET_HREF=$(echo "$STORE_OUT" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if not m:
    m = re.search(r'\[.*\]', text, re.DOTALL)
if m:
    try:
        d = json.loads(m.group(0))
        if isinstance(d, list): d = d[0] if d else {}
        print(d.get('secret_href') or d.get('Secret href') or d.get('href',''))
        sys.exit(0)
    except Exception:
        pass
print('')
" 2>/dev/null)

        if [ -z "$SECRET_HREF" ]; then
            echo "  ERROR: could not parse secret href from Barbican response" >&2
            ERRORS=$((ERRORS + 1))
            IDX=$((IDX + 1))
            continue
        fi

        # Fix https://None:<port>/... if Barbican host_href is not configured
        if echo "$SECRET_HREF" | grep -q '//None:'; then
            echo "  WARNING: Barbican returned None hostname in href, resolving public endpoint..."
            SECRET_UUID="${SECRET_HREF##*/}"
            BARBICAN_URL=$(run_remote "openstack endpoint list --service key-manager --interface public -f value -c URL" | \
                grep -v '^$' | head -1)
            echo "$BARBICAN_URL"
            if [ -n "$BARBICAN_URL" ]; then
                BARBICAN_BASE="${BARBICAN_URL%/}"
                echo "$BARBICAN_BASE" | grep -q '/v1$' || BARBICAN_BASE="${BARBICAN_BASE}/v1"
                SECRET_HREF="${BARBICAN_BASE}/secrets/${SECRET_UUID}"
                echo "  Normalized href: $SECRET_HREF"
            fi
        fi

        if [ -n "$EXISTING_ID" ]; then
            echo "  EXISTS (id=$EXISTING_ID) — updating secret-ref only"
            UPDATE_OUT=$(run_remote "workloadmgr backup-target-update $EXISTING_ID --secret-ref '$SECRET_HREF'")
            echo "$UPDATE_OUT"
            if echo "$UPDATE_OUT" | grep -qiE '^ERROR|^Error:'; then
                echo "  ERROR: update failed for $BT_NAME" >&2
                ERRORS=$((ERRORS + 1))
            else
                echo "  OK: updated $BT_NAME (secret-ref=$SECRET_HREF)"
            fi
        else
            echo "  NOT FOUND — creating S3 backup target"
            CREATE_CMD="workloadmgr backup-target-create --btt-name '$BT_NAME' --type s3 --s3-bucket '$S3_BUCKET' --secret-ref '$SECRET_HREF'"
            [ -n "$S3_ENDPOINT" ] && CREATE_CMD+=" --s3-endpoint-url '$S3_ENDPOINT'"
            [ -n "$DEFAULT_FLAG" ] && CREATE_CMD+=" $DEFAULT_FLAG"
            CREATE_OUT=$(run_remote "$CREATE_CMD")
            echo "$CREATE_OUT"
            if echo "$CREATE_OUT" | grep -qiE '^ERROR|^Error:'; then
                echo "  ERROR: create failed for $BT_NAME" >&2
                ERRORS=$((ERRORS + 1))
            else
                echo "  OK: created $BT_NAME (secret-ref=$SECRET_HREF)"
            fi
        fi
    fi

    IDX=$((IDX + 1))
done < <(echo "$BACKUP_TARGETS_JSON" | python3 -c "
import sys, json
for bt in json.load(sys.stdin):
    print(json.dumps(bt))
")

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo "Done. Errors: $ERRORS"
echo "================================================================="
echo ""
echo "Final backup-target-list:"
run_remote "workloadmgr backup-target-list"

[ "$ERRORS" -gt 0 ] && exit 1 || exit 0
