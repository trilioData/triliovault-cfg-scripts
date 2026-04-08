#!/bin/bash
# collect_backup_targets.sh
#
# T4O 6.0/6.1 → 6.2 Backup Target Migration — Step 1 of 2 (RHOSO18)
#
# Reads backup targets from two sources:
#   1. tvo-operator-inputs.yaml  (triliovault_backup_targets section, if present)
#   2. TVOBackupTarget CR instances in the trilio-openstack namespace
#
# Writes the combined list to: backup_targets_inventory.yaml
#
# Then runs 'workloadmgr backup-target-list' to verify that the inventory
# count and names match exactly what is registered in the WLM database.
# Any mismatch is reported and must be resolved before running
# update_backup_targets_62.sh.
#
# Prerequisites:
#   - oc CLI authenticated (cluster-admin or RBAC covering the actions below)
#       get/list TVOBackupTarget CRs in trilio-openstack
#       exec into pods in trilio-openstack
#       get secret openstack-secret in trilio-openstack or openstack namespace
#   - python3 with PyYAML   (pip3 install pyyaml)
#   - jq
#   - tvo-operator-inputs.yaml in the current directory
#
# Usage:
#   bash collect_backup_targets.sh
#
# Output:
#   existing_list_of_backup_targets.yaml  — input for update_backup_targets_62.sh

set -euo pipefail

NAMESPACE="trilio-openstack"
OPENSTACK_NS="openstack"
INPUTS_FILE="tvo-operator-inputs.yaml"
INVENTORY_FILE="existing_list_of_backup_targets.yaml"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() {
  echo
  echo "================================================================"
  echo "[$(date '+%H:%M:%S')] $*"
  echo "================================================================"
}
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# -----------------------------------------------------------------------
# Prerequisites check
# -----------------------------------------------------------------------
log_step "Checking prerequisites"
for cmd in oc python3 jq; do
  command -v "${cmd}" &>/dev/null || { err "Required command not found: ${cmd}"; exit 1; }
done
python3 -c "import yaml" 2>/dev/null || {
  err "Python3 'yaml' module missing.  Install with: pip3 install pyyaml"; exit 1; }
[ -f "${INPUTS_FILE}" ] || {
  err "${INPUTS_FILE} not found in $(pwd)"; exit 1; }
log "All prerequisites satisfied."

# -----------------------------------------------------------------------
# Step 1: Read backup targets from tvo-operator-inputs.yaml
# -----------------------------------------------------------------------
log_step "Step 1: Read backup targets from ${INPUTS_FILE}"

# NOTE: The operator inputs file is a TVOControlPlane CR (spec: {...}).
#       If your file uses a flat layout (not wrapped under spec:), that is
#       handled automatically below.
#
#       Supported section (T4O 6.0/6.1):
#         spec.triliovault_backup_targets — list of backup targets
#
#       Field names are normalised to a common internal format:
#         backup_target_name → name
#         backup_target_type → type
#         s3_bucket          → bucket
#         s3_endpoint_url    → endpoint_url
#         s3_ssl_enabled     → ssl
#         s3_ssl_verify      → ssl_verify
#         s3_ssl_ca_cert     → ssl_cert  (only when s3_self_signed_cert=true)
#
#       If the section is absent the script logs a notice and moves on.

STATIC_BTS_JSON=$(python3 - <<'PYEOF'
import yaml, json, sys

with open("tvo-operator-inputs.yaml") as f:
    doc = yaml.safe_load(f)

spec = doc.get("spec", doc)   # support both wrapped and flat layouts
bts  = []

for b in spec.get("triliovault_backup_targets", []):
    if not isinstance(b, dict):
        continue
    bt = {
        "name":       b.get("backup_target_name", ""),
        "type":       b.get("backup_target_type", "s3"),
        "source":     "tvo-operator-inputs.yaml",
        "is_default": b.get("is_default", False),
    }
    if not bt["name"]:
        print("[WARN] Entry without backup_target_name — skipping", file=sys.stderr)
        continue
    if bt["type"] == "s3":
        bt["s3_type"]      = b.get("s3_type", "other_s3")
        bt["bucket"]       = b.get("s3_bucket", "")
        bt["endpoint_url"] = b.get("s3_endpoint_url", "")
        bt["ssl"]          = b.get("s3_ssl_enabled", False)
        bt["ssl_verify"]   = b.get("s3_ssl_verify", False)
        if b.get("s3_self_signed_cert") and b.get("s3_ssl_ca_cert"):
            bt["ssl_cert"] = b["s3_ssl_ca_cert"]
    elif bt["type"] == "nfs":
        bt["nfs_shares"]  = b.get("nfs_shares", "")
        bt["nfs_options"] = b.get("nfs_options", "")
    bts.append(bt)

if bts:
    print(f"[INFO] Total from tvo-operator-inputs.yaml: {len(bts)}", file=sys.stderr)
else:
    print("[INFO] No triliovault_backup_targets section found in "
          "tvo-operator-inputs.yaml — relying on TVOBackupTarget CRs.",
          file=sys.stderr)

print(json.dumps(bts))
PYEOF
)

STATIC_COUNT=$(echo "${STATIC_BTS_JSON}" | jq 'length')
log "Backup targets from ${INPUTS_FILE}: ${STATIC_COUNT}"

# -----------------------------------------------------------------------
# Step 2: Read TVOBackupTarget CRs
# -----------------------------------------------------------------------
log_step "Step 2: Read TVOBackupTarget CRs from namespace ${NAMESPACE}"

CR_RAW=$(oc get tvobackuptarget -n "${NAMESPACE}" -o json 2>/dev/null \
         || echo '{"items":[]}')
CR_COUNT=$(echo "${CR_RAW}" | jq '.items | length')
log "TVOBackupTarget CRs found: ${CR_COUNT}"

# Extract fields from each CR.
# T4O 6.0/6.1 stores backup target config under spec.triliovault_backup_target
# (singular, nested) using s3_* prefixed field names.
# Fields are normalised to the same internal format used for the YAML source.
#
# NOTE: CR_RAW is embedded via bash expansion (not piped) to avoid the
#       heredoc/pipe stdin conflict where <<'PYEOF' overrides the pipe fd.
DYNAMIC_BTS_JSON=$(python3 <<PYEOF
import json

data = json.loads(r"""${CR_RAW}""")
bts  = []

for item in data.get("items", []):
    meta    = item.get("metadata", {})
    spec    = item.get("spec", {})
    cr_name = meta.get("name", "")

    # Naming convention: tvobackuptarget-<backup-target-name>
    bt_name = cr_name.replace("tvobackuptarget-", "", 1)

    # Fields are nested under spec.triliovault_backup_target
    bt_spec = spec.get("triliovault_backup_target", spec)

    bt_type = bt_spec.get("backup_target_type",
                bt_spec.get("type", "s3"))

    bt = {
        "source":     "TVOBackupTarget CR",
        "cr_name":    cr_name,
        "is_default": bt_spec.get("is_default", False),
        "name":       bt_spec.get("backup_target_name", bt_name),
        "type":       bt_type,
    }

    if bt_type == "s3":
        bt["s3_type"]      = bt_spec.get("s3_type", "other_s3")
        bt["bucket"]       = bt_spec.get("s3_bucket",
                               bt_spec.get("bucket", ""))
        bt["endpoint_url"] = bt_spec.get("s3_endpoint_url",
                               bt_spec.get("endpoint_url", ""))
        bt["ssl"]          = bt_spec.get("s3_ssl_enabled",
                               bt_spec.get("ssl", False))
        bt["ssl_verify"]   = bt_spec.get("s3_ssl_verify",
                               bt_spec.get("ssl_verify", False))
        if (bt_spec.get("s3_self_signed_cert") and
                bt_spec.get("s3_ssl_ca_cert")):
            bt["ssl_cert"] = bt_spec["s3_ssl_ca_cert"]
        elif bt_spec.get("ssl_cert"):
            bt["ssl_cert"] = bt_spec["ssl_cert"]
    elif bt_type == "nfs":
        bt["nfs_shares"]  = bt_spec.get("nfs_shares",
                              bt_spec.get("nfs_export", ""))
        bt["nfs_options"] = bt_spec.get("nfs_options", "")

    bts.append(bt)

print(json.dumps(bts))
PYEOF
)

DYNAMIC_COUNT=$(echo "${DYNAMIC_BTS_JSON}" | jq 'length')
log "Backup targets from TVOBackupTarget CRs: ${DYNAMIC_COUNT}"

# -----------------------------------------------------------------------
# Step 3: Merge sources and write inventory YAML
# -----------------------------------------------------------------------
log_step "Step 3: Merge and write ${INVENTORY_FILE}"

python3 - <<PYEOF
import json, yaml, sys

static_bts  = json.loads('${STATIC_BTS_JSON}')
dynamic_bts = json.loads(r"""${DYNAMIC_BTS_JSON}""")

# De-duplicate: if the same name appears in both sources, keep the CR
# version (it is the live record) but note the conflict.
all_bts      = list(static_bts)
static_names = {b["name"] for b in static_bts}

for bt in dynamic_bts:
    if bt["name"] in static_names:
        print(f"[INFO] '{bt['name']}' appears in both tvo-operator-inputs.yaml "
              "and as a TVOBackupTarget CR — using CR version.", flush=True)
        all_bts = [b for b in all_bts if b["name"] != bt["name"]]
    all_bts.append(bt)

inventory = {
    "backup_targets": all_bts,
    "total":          len(all_bts),
}

with open("${INVENTORY_FILE}", "w") as f:
    yaml.dump(inventory, f, default_flow_style=False,
              allow_unicode=True, sort_keys=False)

print(f"[INFO] {len(all_bts)} backup target(s) written to ${INVENTORY_FILE}")
PYEOF

log "Inventory file created: ${INVENTORY_FILE}"

# -----------------------------------------------------------------------
# Step 4: Verify inventory against workloadmgr backup-target-list
# -----------------------------------------------------------------------
log_step "Step 4: Verify inventory against workloadmgr backup-target-list"

# Read OpenStack admin settings from tvo-operator-inputs.yaml
_py_spec() {
  python3 -c "
import yaml
doc  = yaml.safe_load(open('${INPUTS_FILE}'))
spec = doc.get('spec', doc)
print(${1})
"
}

OS_AUTH_URL=$(_py_spec "spec['keystone']['common']['auth_uri']")
OS_USERNAME=$(_py_spec "spec['keystone']['common']['cloud_admin_user_name']")
OS_PROJECT=$(_py_spec  "spec['keystone']['common']['cloud_admin_project_name']")
OS_REGION=$(_py_spec   "spec['keystone']['common']['region_name']")
OS_DOMAIN=$(_py_spec   "spec['keystone']['common']['cloud_admin_domain_name']")
OS_INTERFACE=$(_py_spec "spec['keystone']['keystone_interface']")

# Get admin password from openstack-secret
OS_PASSWORD=$(oc get secret openstack-secret -n "${NAMESPACE}" \
  -o jsonpath='{.data.CloudAdminPassword}' 2>/dev/null | base64 -d || true)
if [ -z "${OS_PASSWORD}" ]; then
  OS_PASSWORD=$(oc get secret openstack-secret -n "${OPENSTACK_NS}" \
    -o jsonpath='{.data.CloudAdminPassword}' 2>/dev/null | base64 -d || true)
fi

if [ -z "${OS_PASSWORD}" ]; then
  warn "Could not read CloudAdminPassword from openstack-secret in either namespace."
  warn "Skipping workloadmgr verification. Run manually:"
  warn "  workloadmgr backup-target-list"
  log_step "Done (verification skipped)"
  log "Inventory: ${INVENTORY_FILE}"
  log "Next: review ${INVENTORY_FILE} then run update_backup_targets_62.sh"
  exit 0
fi

# Find a running WLM API pod
WLM_POD=$(oc -n "${NAMESPACE}" get pods \
  -l component=wlm-api \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${WLM_POD}" ]; then
  warn "No running triliovault-wlm-api pod found in ${NAMESPACE}."
  warn "Skipping workloadmgr verification."
  log_step "Done (verification skipped — no running WLM pod)"
  log "Inventory: ${INVENTORY_FILE}"
  exit 0
fi

log "Using WLM pod: ${WLM_POD}"

# Run workloadmgr backup-target-list inside the WLM pod.
# OS_PASSWORD is injected via the exec environment.
WLM_BT_JSON=$(oc exec -n "${NAMESPACE}" "${WLM_POD}" -- bash -c "
  export OS_AUTH_URL='${OS_AUTH_URL}'
  export OS_USERNAME='${OS_USERNAME}'
  export OS_PASSWORD='${OS_PASSWORD}'
  export OS_PROJECT_NAME='${OS_PROJECT}'
  export OS_REGION_NAME='${OS_REGION}'
  export OS_USER_DOMAIN_NAME='${OS_DOMAIN}'
  export OS_PROJECT_DOMAIN_NAME='${OS_DOMAIN}'
  export OS_IDENTITY_API_VERSION=3
  export OS_INTERFACE='${OS_INTERFACE}'
  export OS_CACERT=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
  workloadmgr backup-target-list --format json
" 2>/dev/null || echo "[]")

# -----------------------------------------------------------------------
# Step 5: Compare and report
# -----------------------------------------------------------------------
log_step "Step 5: Compare inventory vs workloadmgr"

python3 - <<PYEOF
import json, yaml, sys

with open("${INVENTORY_FILE}") as f:
    inventory = yaml.safe_load(f)

inv_bts  = inventory.get("backup_targets", [])
inv_names = sorted(b["name"] for b in inv_bts)

try:
    wlm_bts  = json.loads(r"""${WLM_BT_JSON}""")
    wlm_names = sorted(b.get("name", "") for b in wlm_bts)
except Exception as exc:
    print(f"[WARN] Cannot parse workloadmgr output ({exc}). "
          "Verify manually: workloadmgr backup-target-list")
    sys.exit(0)

print(f"\n  Inventory count   : {len(inv_names)}")
print(f"  workloadmgr count : {len(wlm_names)}")

mismatches = False

if len(inv_names) != len(wlm_names):
    print(f"\n[MISMATCH] Counts differ: "
          f"inventory={len(inv_names)}, workloadmgr={len(wlm_names)}")
    mismatches = True

only_in_inv = set(inv_names) - set(wlm_names)
only_in_wlm = set(wlm_names) - set(inv_names)

if only_in_inv:
    print(f"\n[MISMATCH] In inventory but not in workloadmgr:")
    for n in sorted(only_in_inv):
        print(f"  - {n}")

if only_in_wlm:
    print(f"\n[MISMATCH] In workloadmgr but not in inventory:")
    for n in sorted(only_in_wlm):
        print(f"  - {n}  <-- add to ${INVENTORY_FILE} before running "
              "update_backup_targets_62.sh")
    mismatches = True

if not mismatches:
    print("\n[OK] Inventory matches workloadmgr exactly.")
    print(f"     Backup targets: {inv_names}")
else:
    print("\n[ACTION] Correct ${INVENTORY_FILE} before running "
          "update_backup_targets_62.sh")
    sys.exit(1)
PYEOF

log_step "Done"
log "Inventory : ${INVENTORY_FILE}"
log "Next step : Review ${INVENTORY_FILE} then run update_backup_targets_62.sh"
