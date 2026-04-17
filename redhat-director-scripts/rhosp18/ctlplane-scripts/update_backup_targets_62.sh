#!/bin/bash
# update_backup_targets_62.sh
#
# T4O 6.0/6.1 → 6.2 Backup Target Migration — Step 2 of 2 (RHOSO18)
#
# For every S3 backup target in backup_targets_inventory.yaml this script:
#
#   2.1  Reads backup target details from the inventory and finds the
#        matching entry in 'workloadmgr backup-target-list' to get its ID.
#
#   2.2  Creates a DMS secret JSON using 'trilio-dms-cli secret-payload create'
#        and validates it with 'trilio-dms-cli secret-payload validate'.
#        Both tools are available in the trilio-wlm image.
#
#   2.3  Stores the secret payload in Barbican via 'openstack secret store'
#        executed inside the same migration pod (openstack CLI is available
#        in the trilio-wlm image).
#
#   2.4  Updates the backup target record with the new Barbican secret
#        reference via 'workloadmgr backup-target-modify'.
#
# Steps 2.2 and 2.4 (and the initial backup-target-list) run inside a
# single temporary migration pod launched from the trilio-wlm image.
# The pod is modelled after the wlm-api init container:
#   - triliovault-wlm-bin ConfigMap mounted → /tmp/triliovault-cloudrc
#   - combined-ca-bundle secret mounted     → CA cert path
#   - OS_PASSWORD injected from openstack-secret (secretKeyRef)
# Sourcing /tmp/triliovault-cloudrc inside the pod sets all other
# OpenStack env vars (OS_AUTH_URL, OS_USERNAME, etc.).
#
# The trilio-wlm image contains workloadmgr, trilio-dms-cli, and the
# openstack CLI client, so all four steps run inside the single migration
# pod — no separate openstackclient pod is needed.
#
# Prerequisites:
#   - existing_list_of_backup_targets.yaml  (produced by collect_backup_targets.sh)
#   - tvo-operator-inputs.yaml in the current directory
#   - oc CLI with cluster-admin (or equivalent RBAC)
#   - python3 with PyYAML   (pip3 install pyyaml)
#   - jq
#
# Usage:
#   bash update_backup_targets_62.sh [-k]
#
#   -k  Keep the migration pod running after the script exits (useful for
#       debugging — exec into it with:
#         oc exec -it -n trilio-openstack <pod-name> -- bash

set -euo pipefail

KEEP_POD=false

while getopts ":k" opt; do
  case "${opt}" in
    k) KEEP_POD=true ;;
    \?) echo "ERROR: Unknown option -${OPTARG}." >&2
        echo "Usage: $0 [-k]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

NAMESPACE="trilio-openstack"
INPUTS_FILE="tvo-operator-inputs.yaml"
INVENTORY_FILE="existing_list_of_backup_targets.yaml"
WORKDIR="bt-migration-work-$$"
MIGRATE_POD="trilio-bt-migrate-$$"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() {
  echo
  echo "================================================================"
  echo "[$(date '+%H:%M:%S')] $*"
  echo "================================================================"
}
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

cleanup() {
  [ -d "${WORKDIR}" ] && rm -rf "${WORKDIR}"
  if [ "${KEEP_POD}" = "true" ]; then
    log "Keeping migration pod '${MIGRATE_POD}' (sleep 600 — exec in with: oc exec -it -n ${NAMESPACE} ${MIGRATE_POD} -- bash)"
  else
    oc delete pod "${MIGRATE_POD}" -n "${NAMESPACE}" \
      --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

mkdir -p "${WORKDIR}"

# -----------------------------------------------------------------------
# Prerequisites check
# -----------------------------------------------------------------------
log_step "Checking prerequisites"
for cmd in oc python3 jq; do
  command -v "${cmd}" &>/dev/null || { err "Required command not found: ${cmd}"; exit 1; }
done
python3 -c "import yaml" 2>/dev/null || {
  err "PyYAML not installed: pip3 install pyyaml"; exit 1; }
[ -f "${INVENTORY_FILE}" ] || {
  err "${INVENTORY_FILE} not found. Run collect_backup_targets.sh first."; exit 1; }
[ -f "${INPUTS_FILE}" ] || {
  err "${INPUTS_FILE} not found in $(pwd)"; exit 1; }
log "Prerequisites OK."

# -----------------------------------------------------------------------
# Load WLM image from tvo-operator-inputs.yaml
# -----------------------------------------------------------------------
log_step "Loading configuration from ${INPUTS_FILE}"

WLM_IMAGE=$(python3 -c "
import yaml
doc  = yaml.safe_load(open('${INPUTS_FILE}'))
spec = doc.get('spec', doc)
print(spec['images']['triliovault_wlm'])
")
log "WLM image: ${WLM_IMAGE}"

# -----------------------------------------------------------------------
# Launch migration pod  (mirrors the wlm-api init container pattern)
#
# - Mounts triliovault-wlm-bin ConfigMap → /tmp/triliovault-cloudrc
#   (contains pre-rendered OpenStack env vars: OS_AUTH_URL, OS_USERNAME, …)
# - Mounts combined-ca-bundle secret     → CA cert path
# - Injects OS_PASSWORD via secretKeyRef from openstack-secret
#
# After sourcing /tmp/triliovault-cloudrc + OS_PASSWORD the pod can run
# workloadmgr and trilio-dms-cli with full OpenStack credentials.
# -----------------------------------------------------------------------
log_step "Launching migration pod: ${MIGRATE_POD}"

python3 - > "${WORKDIR}/migrate-pod.yaml" <<PYEOF
import yaml

pod = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "name":      "${MIGRATE_POD}",
        "namespace": "${NAMESPACE}",
        "labels":    {"app": "trilio-bt-migrate"},
    },
    "spec": {
        "restartPolicy":      "Never",
        "serviceAccountName": "triliovault-wlm",
        "nodeSelector":       {"trilio-control-plane": "enabled"},
        "volumes": [
            {
                "name":      "triliovault-wlm-bin",
                "configMap": {"name": "triliovault-wlm-bin",
                              "defaultMode": 0o555},
            },
            {
                "name":   "combined-ca-bundle",
                "secret": {"secretName": "combined-ca-bundle",
                           "defaultMode": 0o444},
            },
        ],
        "containers": [{
            "name":            "${MIGRATE_POD}",
            "image":           "${WLM_IMAGE}",
            "imagePullPolicy": "IfNotPresent",
            # Sleep so we can exec into the pod for each operation
            "command": ["/bin/bash", "-c", "sleep 600"],
            "env": [
                # OS_PASSWORD mirrors the wlm-api init container setup
                {
                    "name": "OS_PASSWORD",
                    "valueFrom": {
                        "secretKeyRef": {
                            "name": "openstack-secret",
                            "key":  "CloudAdminPassword",
                        }
                    },
                },
            ],
            "volumeMounts": [
                # triliovault-cloudrc provides all other OS_* vars
                {
                    "name":      "triliovault-wlm-bin",
                    "mountPath": "/tmp/triliovault-cloudrc",
                    "subPath":   "triliovault-cloudrc",
                },
                {
                    "name":      "combined-ca-bundle",
                    "mountPath": "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
                    "subPath":   "tls-ca-bundle.pem",
                    "readOnly":  True,
                },
            ],
        }],
    },
}

print(yaml.dump(pod, default_flow_style=False))
PYEOF

oc apply -f "${WORKDIR}/migrate-pod.yaml" >/dev/null
log "Waiting for migration pod to be ready ..."
oc wait pod "${MIGRATE_POD}" -n "${NAMESPACE}" \
  --for=condition=Ready --timeout=120s >/dev/null
log "Migration pod is ready."

# -----------------------------------------------------------------------
# Helper: exec a command inside the migration pod.
# Sourcing /tmp/triliovault-cloudrc provides all OS_* vars;
# OS_PASSWORD is already set from the secretKeyRef above.
# -----------------------------------------------------------------------
exec_in_pod() {
  oc exec -n "${NAMESPACE}" "${MIGRATE_POD}" -- bash -c "
    source /tmp/triliovault-cloudrc
    unset OS_PROJECT_ID
    $*
  " 2>/dev/null
}

# -----------------------------------------------------------------------
# Step 1: Get workloadmgr backup-target-list (ID mapping)
# -----------------------------------------------------------------------
log_step "Step 1: Get workloadmgr backup-target-list"

WLM_BT_JSON=$(exec_in_pod "workloadmgr backup-target-list --format json" || echo "[]")
BT_COUNT=$(echo "${WLM_BT_JSON}" | jq 'length')
log "workloadmgr reports ${BT_COUNT} backup target(s)."

# Match by S3 bucket name — workloadmgr backup-target-list --format json
# returns the bucket/endpoint in "Backend Endpoint" field.
# Format is either:
#   plain bucket name      →  "trilio-qa"
#   host:port/bucket-name  →  "ceph-aio.example.com:8080/bucket1"
# So we match on exact equality OR on the last path component after '/'.
get_bt_id_by_bucket() {
  echo "${WLM_BT_JSON}" | jq -r --arg b "$1" \
    '.[] | select(
      (."Backend Endpoint" // "") == $b or
      ((."Backend Endpoint" // "") | split("/") | last) == $b
    ) | .ID'
}

get_wlm_name_by_bucket() {
  echo "${WLM_BT_JSON}" | jq -r --arg b "$1" \
    '.[] | select(
      (."Backend Endpoint" // "") == $b or
      ((."Backend Endpoint" // "") | split("/") | last) == $b
    ) | ."Backend Endpoint"'
}

# -----------------------------------------------------------------------
# Step 2: Process each backup target from the inventory
# -----------------------------------------------------------------------
log_step "Step 2: Process backup targets"

BT_JSON_LIST=$(python3 -c "
import yaml, json
inv = yaml.safe_load(open('${INVENTORY_FILE}'))
print(json.dumps(inv.get('backup_targets', [])))")

TOTAL=$(echo "${BT_JSON_LIST}" | jq 'length')
log "Total backup targets in inventory: ${TOTAL}"

PASS=0; FAIL=0; SKIP=0

for i in $(seq 0 $((TOTAL - 1))); do
  BT=$(echo "${BT_JSON_LIST}" | jq ".[${i}]")
  BT_NAME=$(echo "${BT}" | jq -r '.name')
  BT_TYPE=$(echo "${BT}" | jq -r '.type // "s3"')
  BUCKET=$(echo "${BT}"  | jq -r '.bucket // empty')

  log ""
  log "---------------------------------------------"
  log "[${i}/${TOTAL}] Backup target: ${BT_NAME}  bucket: ${BUCKET}"
  log "---------------------------------------------"

  # ------------------------------------------------------------------
  # Step 2.1: Find backup target ID in workloadmgr by S3 bucket name
  # ------------------------------------------------------------------
  if [ -z "${BUCKET}" ]; then
    err "  No bucket configured for '${BT_NAME}'. Skipping."
    SKIP=$((SKIP + 1))
    continue
  fi
  BT_ID=$(get_bt_id_by_bucket "${BUCKET}")
  if [ -z "${BT_ID}" ]; then
    warn "  No workloadmgr entry with bucket '${BUCKET}' (inventory name: '${BT_NAME}'). Skipping."
    SKIP=$((SKIP + 1))
    continue
  fi
  WLM_NAME=$(get_wlm_name_by_bucket "${BUCKET}")
  log "  Matched WLM entry: '${WLM_NAME}' (id=${BT_ID})"

  # ------------------------------------------------------------------
  # S3: validate required fields
  # ------------------------------------------------------------------
  ENDPOINT_URL=$(echo "${BT}" | jq -r '.endpoint_url // empty')
  SSL=$(echo "${BT}"          | jq -r '.ssl          // false')
  SSL_VERIFY=$(echo "${BT}"   | jq -r '.ssl_verify   // false')
  SSL_CERT=$(echo "${BT}"     | jq -r '.ssl_cert     // empty')
  S3_TYPE=$(echo "${BT}"      | jq -r '.s3_type      // "other_s3"')

  # S3 credentials are read from the inventory file, which was populated by
  # collect_backup_targets.sh from trilio-openstack-secret on the 6.1 cluster
  # before upgrade (6.2 removes those keys from trilio-openstack-secret).
  ACCESS_KEY=$(echo "${BT}" | jq -r '.access_key // empty')
  SECRET_KEY=$(echo "${BT}" | jq -r '.secret_key // empty')

  if [ -z "${ACCESS_KEY}" ] || [ -z "${SECRET_KEY}" ]; then
    err "  S3 credentials missing for '${BT_NAME}' in ${INVENTORY_FILE}."
    err "  Re-run collect_backup_targets.sh against the 6.1 cluster to collect credentials."
    FAIL=$((FAIL + 1))
    continue
  fi

  # endpoint_url is optional for amazon_s3 (AWS handles routing internally)
  if [ -z "${ENDPOINT_URL}" ] && [ "${S3_TYPE}" != "amazon_s3" ]; then
    err "  Missing endpoint_url for non-Amazon S3 target '${BT_NAME}'. Skipping."
    FAIL=$((FAIL + 1))
    continue
  fi

  BT_WORKDIR="${WORKDIR}/${BT_NAME}"
  mkdir -p "${BT_WORKDIR}"
  SECRET_JSON_FILE="secret-${BT_NAME}.json"
  POD_SECRET_JSON="/tmp/${SECRET_JSON_FILE}"
  POD_CERT_FILE="/tmp/ca-cert-${BT_NAME}.pem"

  # ------------------------------------------------------------------
  # Step 2.2: Create and validate DMS secret JSON inside migration pod.
  # trilio-dms-cli is available in the trilio-wlm image.
  # ------------------------------------------------------------------
  log "  Step 2.2: Creating DMS secret JSON with trilio-dms-cli ..."

  # If a self-signed SSL cert is provided, copy it into the pod via stdin
  HAS_SSL_CERT=false
  if [ -n "${SSL_CERT}" ] && [ "${SSL_VERIFY}" = "true" ]; then
    HAS_SSL_CERT=true
    log "  Writing SSL cert to migration pod at ${POD_CERT_FILE} ..."
    echo "${SSL_CERT}" | oc exec -i -n "${NAMESPACE}" "${MIGRATE_POD}" -- \
      bash -c "cat > ${POD_CERT_FILE}"
  fi

  # Build trilio-dms-cli argument list
  # --filesystem-export is the Backend Endpoint value from workloadmgr
  # backup-target-list (same as filesystem_export in backup-target-show).
  DMS_CMD="trilio-dms-cli secret-payload create"
  DMS_CMD="${DMS_CMD} --access-key '${ACCESS_KEY}'"
  DMS_CMD="${DMS_CMD} --secret-key '${SECRET_KEY}'"
  DMS_CMD="${DMS_CMD} --bucket '${BUCKET}'"
  DMS_CMD="${DMS_CMD} --filesystem-export '${WLM_NAME}'"
  DMS_CMD="${DMS_CMD} --endpoint-url '${ENDPOINT_URL}'"
  [ "${SSL}"            = "true" ] && DMS_CMD="${DMS_CMD} --ssl"
  [ "${SSL_VERIFY}"     = "true" ] && DMS_CMD="${DMS_CMD} --ssl-verify"
  [ "${HAS_SSL_CERT}"   = "true" ] && DMS_CMD="${DMS_CMD} --ssl-cert ${POD_CERT_FILE}"
  DMS_CMD="${DMS_CMD} -o ${POD_SECRET_JSON}"

  VALIDATE_CMD="trilio-dms-cli secret-payload validate ${POD_SECRET_JSON}"

  # Run create → validate → print JSON in a single exec call
  RAW_OUTPUT=$(exec_in_pod \
    "${DMS_CMD} && ${VALIDATE_CMD} && cat ${POD_SECRET_JSON}" || echo "")

  if [ -z "${RAW_OUTPUT}" ]; then
    err "  trilio-dms-cli failed for '${BT_NAME}'."
    # Clean up cert from pod on failure
    oc exec -n "${NAMESPACE}" "${MIGRATE_POD}" -- \
      bash -c "rm -f ${POD_CERT_FILE}" 2>/dev/null || true
    FAIL=$((FAIL + 1))
    continue
  fi

  # Save raw output and extract the JSON object from it
  # (trilio-dms-cli may print status lines before the JSON payload)
  echo "${RAW_OUTPUT}" > "${BT_WORKDIR}/dms-output.txt"
  SECRET_JSON=$(python3 <<PYEOF
import json, re

with open("${BT_WORKDIR}/dms-output.txt") as f:
    raw = f.read()

m = re.search(r'\{.*\}', raw, re.DOTALL)
if m:
    try:
        print(json.dumps(json.loads(m.group())))
    except json.JSONDecodeError:
        pass
PYEOF
)

  if [ -z "${SECRET_JSON}" ]; then
    err "  Could not parse secret JSON from trilio-dms-cli output."
    err "  Raw output: ${BT_WORKDIR}/dms-output.txt"
    oc exec -n "${NAMESPACE}" "${MIGRATE_POD}" -- \
      bash -c "rm -f ${POD_SECRET_JSON} ${POD_CERT_FILE}" 2>/dev/null || true
    FAIL=$((FAIL + 1))
    continue
  fi

  echo "${SECRET_JSON}" > "${BT_WORKDIR}/${SECRET_JSON_FILE}"
  log "  Secret JSON saved locally: ${BT_WORKDIR}/${SECRET_JSON_FILE}"

  # ------------------------------------------------------------------
  # Step 2.3: Create Barbican secret using 'openstack secret store'.
  # The trilio-wlm image includes the openstack CLI client, so we run
  # this directly in the migration pod using the same credentials.
  # The secret JSON is already at ${POD_SECRET_JSON} on the pod.
  # ------------------------------------------------------------------
  log "  Step 2.3: Storing secret in Barbican ..."

  BARBICAN_SECRET_NAME="secret-key-${BT_NAME}"

  BARBICAN_OUTPUT=$(exec_in_pod "
    openstack secret store \
      --name '${BARBICAN_SECRET_NAME}' \
      --payload \"\$(cat ${POD_SECRET_JSON})\" \
      -f json
  " 2>/dev/null || echo "")

  # Clean up secret JSON and cert from migration pod
  oc exec -n "${NAMESPACE}" "${MIGRATE_POD}" -- \
    bash -c "rm -f ${POD_SECRET_JSON} ${POD_CERT_FILE}" 2>/dev/null || true

  if [ -z "${BARBICAN_OUTPUT}" ]; then
    err "  'openstack secret store' returned no output for '${BT_NAME}'."
    FAIL=$((FAIL + 1))
    continue
  fi

  # Parse the secret href — handles both dict and single-item list output
  SECRET_HREF=$(echo "${BARBICAN_OUTPUT}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, list):
    data = data[0] if data else {}
print(data.get('secret_href')
   or data.get('Secret href')
   or data.get('href', ''))
" 2>/dev/null || echo "")

  if [ -z "${SECRET_HREF}" ]; then
    err "  Cannot parse secret href from Barbican output for '${BT_NAME}'."
    err "  Raw output: ${BARBICAN_OUTPUT}"
    FAIL=$((FAIL + 1))
    continue
  fi

  # The href returned by 'openstack secret store' uses the endpoint the CLI
  # connected to (often http:// internal hostname), which differs from the
  # https:// public endpoint that workloadmgr uses to validate secret_ref.
  # Fix: query the keystone catalog for the Barbican public endpoint and
  # rebuild the href keeping only the secret UUID from the returned value.
  SECRET_UUID=$(echo "${SECRET_HREF}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || echo "")
  # Query the Barbican public endpoint using OS_INTERFACE=public explicitly
  # so the keystone catalog lookup uses the public URL, not the internal one
  # set in triliovault-cloudrc.
  BARBICAN_ENDPOINT=$(oc exec -n "${NAMESPACE}" "${MIGRATE_POD}" -- bash -c "
    source /tmp/triliovault-cloudrc
    unset OS_PROJECT_ID
    OS_INTERFACE=public openstack endpoint list \
      --service key-manager --interface public -f json 2>/dev/null | \
    python3 -c \"
import json, sys
eps = json.load(sys.stdin)
url = eps[0].get('URL', '').rstrip('/') if eps else ''
if url.endswith('/v1'):
    url = url[:-3]
print(url)
\"
  " 2>/dev/null || echo "")

  if [ -z "${SECRET_UUID}" ]; then
    err "  Could not extract secret UUID from Barbican href '${SECRET_HREF}'."
    FAIL=$((FAIL + 1))
    continue
  fi

  if [ -z "${BARBICAN_ENDPOINT}" ]; then
    err "  Could not determine Barbican public endpoint from keystone catalog."
    FAIL=$((FAIL + 1))
    continue
  fi

  SECRET_HREF="${BARBICAN_ENDPOINT}/v1/secrets/${SECRET_UUID}"
  log "  Normalised Barbican secret href: ${SECRET_HREF}"

  log "  Barbican secret: ${SECRET_HREF}"

  # ------------------------------------------------------------------
  # Step 2.4: Update backup target record with the new Barbican secret
  # ------------------------------------------------------------------
  log "  Step 2.4: Updating '${WLM_NAME}' (bucket=${BUCKET}, id=${BT_ID}) ..."

  WLM_UPDATE_CMD="workloadmgr backup-target-modify --secret-ref '${SECRET_HREF}' ${BT_ID}"
  log "  Update command: ${WLM_UPDATE_CMD}"

  UPDATE_OUTPUT=$(exec_in_pod "${WLM_UPDATE_CMD}" 2>&1 || echo "FAILED")
  log "  Update output: ${UPDATE_OUTPUT}"

  if echo "${UPDATE_OUTPUT}" | grep -qiE "^FAILED|[Ee]rror"; then
    err "  workloadmgr backup-target-modify failed for '${BT_NAME}':"
    err "  ${UPDATE_OUTPUT}"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Verify secret_ref was persisted
  VERIFY_OUTPUT=$(exec_in_pod \
    "workloadmgr backup-target-show ${BT_ID} --format json" 2>/dev/null || echo "[]")
  SECRET_REF_STORED=$(echo "${VERIFY_OUTPUT}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    val = next((d.get('Value','') for d in data if d.get('Field') == 'secret_ref'), '')
else:
    val = data.get('secret_ref', '')
print(val or 'None')
" 2>/dev/null || echo "unknown")
  log "  secret_ref after update: ${SECRET_REF_STORED}"

  log "  Backup target '${BT_NAME}' updated successfully."
  PASS=$((PASS + 1))
done

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
log_step "Migration Summary"
log "  Succeeded : ${PASS}"
log "  Failed    : ${FAIL}"
log "  Skipped   : ${SKIP}  (not found in workloadmgr)"
log "  Total     : ${TOTAL}"

if [ "${FAIL}" -gt 0 ]; then
  err "${FAIL} backup target(s) failed. Review the log above and re-run."
  exit 1
fi

log "All S3 backup targets migrated successfully."
