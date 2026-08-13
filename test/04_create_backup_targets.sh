#!/usr/bin/env bash
# 04_create_backup_targets.sh — create the selected backup target(s).
#
# Creates ONLY the target(s) named by T4O_BT_SCOPE. A type that was not selected
# is never created and never touched, even if it already exists on the cloud.
#
# Reachability was already proven in step 01, so there is no probing here — this
# step is creation only. If step 01 was resolved by swapping to a different
# entry (T4O_S3_TARGET / T4O_NFS_TARGET), the same entry is used here.
#
# ORDERING: this must run AFTER the cloud admin trust (step 03).
# backup-target-create performs a trust lookup and fails with
#   "No cloud admin trust found. Please recreate using CLI"
# if the trust does not exist yet.
#
# S3 credentials go into Barbican and the target stores only a secret_ref.
# Two things that must not drift:
#   - payload_content_type MUST be text/plain. Barbican rejects application/json;
#     the DMS payload is JSON stored as opaque text, which DMS reads fine.
#   - Use the PUBLIC key-manager endpoint from the Keystone catalog. Compute
#     nodes cannot reach cluster-internal ClusterIPs, and the DataMover is the
#     component that resolves the secret at backup time.
#   - Store the ref exactly as Barbican returns it. WLM appends /payload itself
#     at fetch time; appending it here yields .../payload/payload and a 404 that
#     surfaces as the target going offline.
#
# Usage: bash 04_create_backup_targets.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init
t4o_load_backup_targets

t4o_info ""
t4o_info "=== Step 4: Create backup target(s) (scope: $T4O_BT_SCOPE) ==="

CREATED_FILE="${T4O_WORK_DIR}/backup_targets.env"
: > "$CREATED_FILE"

# Two distinct objects, and confusing them is the easy mistake here:
#
#   backup target      the storage itself. Identified by "Backend Endpoint"
#                      (the filesystem_export). It has NO name column.
#   backup target type the NAMED abstraction over a backup target, created by
#                      --btt-name. This name is what workload-create consumes
#                      via --backup-target-type.
#
# So existence is decided by endpoint, and the name we must hand to step 07 is
# whatever BTT already points at that endpoint — which is often NOT the name in
# backup_targets.yaml. On this lab the export is registered as "BT_NFS_LAB"
# while the yaml calls it "BT_NFS"; building a workload on "BT_NFS" would fail.

# backup target ID whose Backend Endpoint matches $1, or empty.
target_id_for_endpoint() {
    wlm_exec backup-target-list -f value -c ID -c "Backend Endpoint" 2>/dev/null | t4o_denoise \
      | awk -v ep="$1" '$2==ep {print $1; exit}'
}

# BTT name pointing at backup target ID $1, or empty.
btt_name_for_target_id() {
    wlm_exec backup-target-type-list -f value -c Name -c "Backup Target ID" 2>/dev/null | t4o_denoise \
      | awk -v id="$1" '$2==id {print $1; exit}'
}

# Effective BTT name for an endpoint that already exists, or empty.
existing_btt_for_endpoint() {
    local tid; tid="$(target_id_for_endpoint "$1")"
    [[ -z "$tid" ]] && return 1
    btt_name_for_target_id "$tid"
}

# ---------------------------------------------------------------------------
# S3
# ---------------------------------------------------------------------------
create_s3() {
    local name="$BT_S3_NAME" ep existing
    # S3 backend endpoint as the list renders it: host/bucket, scheme stripped.
    ep="${BT_S3_ENDPOINT#https://}"; ep="${ep#http://}/$BT_S3_BUCKET"

    if existing="$(existing_btt_for_endpoint "$ep")" && [[ -n "$existing" ]]; then
        t4o_info "  S3 storage '$ep' already registered as backup target type '$existing' — reusing it."
        echo "BT_S3_BTT_NAME='$existing'" >> "$CREATED_FILE"
        return 0
    fi

    t4o_info "  Creating S3 target '$name' (endpoint $BT_S3_ENDPOINT, bucket $BT_S3_BUCKET)"

    # filesystem_export is host/bucket with the scheme stripped.
    local fs_export="${BT_S3_ENDPOINT#https://}"; fs_export="${fs_export#http://}/$BT_S3_BUCKET"

    local ssl_cert_arg=""
    if [[ -n "${BT_S3_CA_CERT_FILE:-}" && -f "$BT_S3_CA_CERT_FILE" ]]; then
        copy_to_wlm "$BT_S3_CA_CERT_FILE" /tmp/t4o-s3-ca.pem
        ssl_cert_arg="--ssl-cert /tmp/t4o-s3-ca.pem"
        t4o_info "    CA cert supplied — passing it to the secret payload."
    fi

    local ssl_args=""
    [[ "$BT_S3_SSL" == "true" ]]        && ssl_args="--ssl"
    [[ "$BT_S3_SSL_VERIFY" == "true" ]] && ssl_args="$ssl_args --ssl-verify"

    # 1. Build the DMS secret payload inside the WLM service.
    wlm_shell "env VAULT_S3_ACCESS_KEY_ID='$BT_S3_ACCESS_KEY' \
                   VAULT_S3_SECRET_ACCESS_KEY='$BT_S3_SECRET_KEY' \
               trilio-dms-cli secret-payload create \
                 --bucket '$BT_S3_BUCKET' \
                 --endpoint-url '$BT_S3_ENDPOINT' \
                 --filesystem-export '$fs_export' \
                 --region '$BT_S3_REGION' \
                 --auth-version '$BT_S3_AUTH_VERSION' \
                 --signature-version '$BT_S3_SIG_VERSION' \
                 $ssl_args $ssl_cert_arg \
                 -o /tmp/t4o_s3_secret.json" >/dev/null \
      || t4o_die "Failed to build the S3 secret payload."

    # 2. Store it in Barbican and capture the ref.
    local secret_ref
    secret_ref="$(store_secret_in_barbican trilio-test-s3 /tmp/t4o_s3_secret.json)"
    [[ -n "$secret_ref" ]] || t4o_die "Barbican did not return a secret_ref."
    t4o_info "    secret_ref: $secret_ref"

    local default_flag=""
    [[ "$BT_S3_IS_DEFAULT" == "true" ]] && default_flag="--default"

    wlm_exec backup-target-create \
        --btt-name "$name" \
        --type s3 \
        --s3-endpoint-url "$BT_S3_ENDPOINT" \
        --s3-bucket "$BT_S3_BUCKET" \
        --secret-ref "$secret_ref" \
        $default_flag -f json 2>&1 | t4o_denoise | sed 's/^/    /'

    wlm_shell "rm -f /tmp/t4o_s3_secret.json /tmp/t4o-s3-ca.pem" >/dev/null 2>&1 || true
    echo "BT_S3_BTT_NAME='$name'" >> "$CREATED_FILE"
}

# Stores <local-json-in-wlm> in Barbican, prints the secret_ref.
# Run from inside the WLM service: the build host often lacks the
# barbicanclient plugin, and the pod already has python3-requests.
store_secret_in_barbican() {
    local secret_name="$1" payload_path="$2"
    local script="${T4O_WORK_DIR}/barbican_put.py"

    cat > "$script" <<'PYEOF'
import os, sys, json, warnings
import requests
warnings.filterwarnings('ignore')

name, payload_file = sys.argv[1], sys.argv[2]

auth = requests.post(os.environ['OS_AUTH_URL'] + '/auth/tokens', verify=False, json={
    'auth': {
        'identity': {'methods': ['password'], 'password': {'user': {
            'name': os.environ['OS_USERNAME'],
            'domain': {'name': os.environ['OS_USER_DOMAIN_NAME']},
            'password': os.environ['OS_PASSWORD']}}},
        'scope': {'project': {'name': os.environ['OS_PROJECT_NAME'],
                              'domain': {'name': os.environ['OS_PROJECT_DOMAIN_NAME']}}}}})
auth.raise_for_status()
token = auth.headers['X-Subject-Token']

# PUBLIC key-manager endpoint: compute nodes cannot reach ClusterIPs, and the
# DataMover is what resolves this ref at backup time.
base = None
for svc in auth.json()['token']['catalog']:
    if svc['type'] == 'key-manager':
        for ep in svc['endpoints']:
            if ep['interface'] == 'public':
                base = ep['url'].rstrip('/')
if not base:
    sys.exit('ERROR: no public key-manager endpoint in the Keystone catalog')

url = base + '/v1/secrets'
hdrs = {'X-Auth-Token': token}

# Replace any same-named secret so re-runs are idempotent. The name is
# test-scoped so this cannot collide with a real credential.
for s in requests.get(url, headers=hdrs, params={'name': name}, verify=False).json().get('secrets', []):
    requests.delete(s['secret_ref'], headers=hdrs, verify=False)
    print('REPLACED:' + s['secret_ref'], file=sys.stderr)

payload = open(payload_file).read().strip()
r = requests.post(url, headers={**hdrs, 'Content-Type': 'application/json'},
                  json={'name': name, 'payload': payload,
                        'payload_content_type': 'text/plain',   # NOT application/json
                        'secret_type': 'opaque'}, verify=False)
r.raise_for_status()
print(r.json()['secret_ref'])
PYEOF

    copy_to_wlm "$script" /tmp/barbican_put.py
    wlm_exec_python /tmp/barbican_put.py "$secret_name" "$payload_path"
    wlm_shell "rm -f /tmp/barbican_put.py" >/dev/null 2>&1 || true
}

wlm_exec_python() {
    local script="$1"; shift
    case "$T4O_DISTRO" in
      sunbeam)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
          env $(_t4o_os_env_args) python3 "$script" "$@" 2>/dev/null ;;
      openstack-helm)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_DEPLOY" -- \
          env $(_t4o_os_env_args) python3 "$script" "$@" 2>/dev/null ;;
      rhoso18)
        oc -n "$K8S_NAMESPACE" exec "$WLM_DEPLOY" -- \
          env $(_t4o_os_env_args) python3 "$script" "$@" 2>/dev/null ;;
      kolla)
        docker exec $(printf -- '-e %s ' $(_t4o_os_env_args)) "$WLM_CTR" python3 "$script" "$@" 2>/dev/null ;;
      rhosp17)
        sudo podman exec $(printf -- '-e %s ' $(_t4o_os_env_args)) "$WLM_CTR" python3 "$script" "$@" 2>/dev/null ;;
      canonical)
        juju ssh trilio-wlm/leader -- "env $(_t4o_os_env_args) python3 $script $*" 2>/dev/null ;;
    esac | tail -1
}

# ---------------------------------------------------------------------------
# NFS
# ---------------------------------------------------------------------------
create_nfs() {
    local name="$BT_NFS_NAME" existing
    # Do NOT split the export on '/' to derive server or path — that mangles
    # exports whose path contains slashes and caused TVAULT-7419. Match it whole.
    if existing="$(existing_btt_for_endpoint "$BT_NFS_EXPORT")" && [[ -n "$existing" ]]; then
        t4o_info "  NFS export '$BT_NFS_EXPORT' already registered as backup target type '$existing' — reusing it."
        echo "BT_NFS_BTT_NAME='$existing'" >> "$CREATED_FILE"
        return 0
    fi

    t4o_info "  Creating NFS target '$name' (export $BT_NFS_EXPORT)"
    wlm_exec backup-target-create \
        --btt-name "$name" \
        --type nfs \
        --filesystem-export "$BT_NFS_EXPORT" \
        --nfs-mount-opts "$BT_NFS_MOUNT_OPTS" \
        -f json 2>&1 | t4o_denoise | sed 's/^/    /'
    echo "BT_NFS_BTT_NAME='$name'" >> "$CREATED_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
t4o_scope_includes s3  && create_s3
t4o_scope_includes nfs && create_nfs

t4o_info ""
t4o_info "Backup targets now defined:"
wlm_exec backup-target-list 2>&1 | t4o_denoise | sed 's/^/  /'

# Every selected target must be online before workloads are built on it.
rc=0
for kind in s3 nfs; do
    t4o_scope_includes "$kind" || continue
    if [[ "$kind" == "s3" ]]; then
        ep="${BT_S3_ENDPOINT#https://}"; ep="${ep#http://}/$BT_S3_BUCKET"
    else
        ep="$BT_NFS_EXPORT"
    fi
    status=$(wlm_exec backup-target-list -f value -c "Backend Endpoint" -c Status 2>/dev/null | t4o_denoise \
             | awk -v e="$ep" '$1==e {print $2}')
    if [[ "$status" == "online" ]]; then
        t4o_info "  $ep: online"
    else
        t4o_error "  $ep: status='${status:-unknown}' (expected 'online')"
        t4o_error "    A target that is present but not online usually means the credential"
        t4o_error "    fetch failed — check that the secret_ref resolves and that nothing"
        t4o_error "    appended /payload to it."
        rc=1
    fi
done

t4o_info "Selected target names saved to: $CREATED_FILE"
exit $rc
