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
#   - tvo-operator-inputs.yaml (path supplied via -i or defaults to ./tvo-operator-inputs.yaml)
#
# Usage:
#   bash collect_backup_targets.sh [-i <path/to/tvo-operator-inputs.yaml>]
#
# Output:
#   existing_list_of_backup_targets.yaml  — input for update_backup_targets_62.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
INPUTS_FILE="tvo-operator-inputs.yaml"   # default

while getopts ":i:" opt; do
  case "${opt}" in
    i) INPUTS_FILE="${OPTARG}" ;;
    :) echo "ERROR: -${OPTARG} requires an argument." >&2; exit 1 ;;
    \?) echo "ERROR: Unknown option -${OPTARG}." >&2
        echo "Usage: $0 [-i <path/to/tvo-operator-inputs.yaml>]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

NAMESPACE="trilio-openstack"
OPENSTACK_NS="openstack"
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
  err "${INPUTS_FILE} not found"; exit 1; }
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
#         backup_target_type → type            (s3 or nfs)
#         s3_bucket          → bucket          (s3 only)
#         s3_endpoint_url    → endpoint_url    (s3 only)
#         s3_ssl_enabled     → ssl             (s3 only)
#         s3_ssl_verify      → ssl_verify      (s3 only)
#         s3_ssl_ca_cert     → ssl_cert        (s3 only, when s3_self_signed_cert=true)
#         nfs_shares         → nfs_shares      (nfs only)
#         nfs_options        → nfs_options     (nfs only)
#
#       If the section is absent the script logs a notice and moves on.
#       Any other backup_target_type is unsupported and skipped with a warning.

STATIC_BTS_JSON=$(python3 - "${INPUTS_FILE}" <<'PYEOF'
import yaml, json, sys

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

spec = doc.get("spec", doc)   # support both wrapped and flat layouts
bts  = []

for b in spec.get("triliovault_backup_targets", []):
    if not isinstance(b, dict):
        continue
    bt = {
        "name":       b.get("backup_target_name", ""),
        "type":       b.get("backup_target_type", "s3"),
        "source":     sys.argv[1],
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
    else:
        print(f"[WARN] '{bt['name']}' type='{bt['type']}' — skipping (unsupported type)",
              file=sys.stderr)
        continue
    bts.append(bt)

if bts:
    print(f"[INFO] Total from {sys.argv[1]}: {len(bts)}", file=sys.stderr)
else:
    print(f"[INFO] No triliovault_backup_targets section found in "
          f"{sys.argv[1]} — relying on TVOBackupTarget CRs.",
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
# (singular, nested) using s3_* (S3) or nfs_* (NFS) prefixed field names.
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
        bt["nfs_shares"]  = bt_spec.get("nfs_shares", "")
        bt["nfs_options"] = bt_spec.get("nfs_options", "")
    else:
        continue  # unsupported type

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

static_bts  = json.loads(r"""${STATIC_BTS_JSON}""")
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
# Step 4: Collect S3 credentials (6.1 cluster — must run BEFORE upgrade)
#
# NFS targets have no vault credentials and are skipped in this step.
#
# Credential source depends on how the backup target was added:
#
#   tvo-operator-inputs.yaml → trilio-openstack-secret
#                              keys: <bt-name>_s3_access_key
#                                    <bt-name>_s3_secret_key
#
#   TVOBackupTarget CR       → trilio-s3-backup-target-secret-<bt-name>
#                              keys: <bt-name>_s3_access_key
#                                    <bt-name>_s3_secret_key
#
# Both secrets are removed in 6.2, so credentials must be collected here.
# -----------------------------------------------------------------------
log_step "Step 4: Collect S3 credentials"

# Fetch trilio-openstack-secret (for YAML-sourced targets)
OS_SECRET_JSON=$(oc get secret trilio-openstack-secret -n "${NAMESPACE}" \
  -o json 2>/dev/null || echo '{}')
OPENSTACK_SECRET_DATA=$(echo "${OS_SECRET_JSON}" | jq -c '.data // {}')

# For each TVOBackupTarget CR target, fetch its dedicated secret and collect
# credentials into a temp JSON file: { "<bt-name>": {"access_key":…, "secret_key":…} }
CR_CREDS_FILE=$(mktemp)
echo '{}' > "${CR_CREDS_FILE}"

while IFS= read -r bt_name; do
  [ -z "${bt_name}" ] && continue
  # K8s resource names cannot contain underscores — normalise bt_name for
  # the secret name only; data keys inside the secret keep the original name.
  SECRET_NAME="trilio-s3-backup-target-secret-${bt_name//_/-}"
  log "  Reading ${SECRET_NAME} ..."
  AK_B64=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o json 2>/dev/null | jq -r --arg k "${bt_name}_s3_access_key" '.data[$k] // empty' || true)
  SK_B64=$(oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    -o json 2>/dev/null | jq -r --arg k "${bt_name}_s3_secret_key" '.data[$k] // empty' || true)
  if [ -n "${AK_B64}" ] && [ -n "${SK_B64}" ]; then
    python3 -c "
import json, base64
with open('${CR_CREDS_FILE}') as fh: d = json.load(fh)
d['${bt_name}'] = {
    'access_key': base64.b64decode('${AK_B64}').decode(),
    'secret_key': base64.b64decode('${SK_B64}').decode(),
}
with open('${CR_CREDS_FILE}', 'w') as fh: json.dump(d, fh)
"
  else
    warn "  Credentials not found in ${SECRET_NAME}"
  fi
done < <(python3 -c "
import yaml
with open('${INVENTORY_FILE}') as f:
    inv = yaml.safe_load(f)
for bt in inv.get('backup_targets', []):
    if bt.get('type') == 's3' and 'TVOBackupTarget CR' in bt.get('source', ''):
        print(bt['name'])
")

# Merge all collected credentials into the inventory
python3 - <<PYEOF
import json, yaml, base64, sys, os

os_data  = json.loads(r"""${OPENSTACK_SECRET_DATA}""")
with open("${CR_CREDS_FILE}") as fh:
    cr_creds = json.load(fh)

def decode(val):
    return base64.b64decode(val).decode() if val else ""

with open("${INVENTORY_FILE}") as f:
    inventory = yaml.safe_load(f)

bts     = inventory.get("backup_targets", [])
missing = []

s3_bts = [bt for bt in bts if bt.get("type") == "s3"]

for bt in s3_bts:
    name   = bt["name"]
    source = bt.get("source", "")

    if "TVOBackupTarget CR" in source:
        # Per-target secret: trilio-s3-backup-target-secret-<bt-name>
        creds = cr_creds.get(name, {})
        ak    = creds.get("access_key", "")
        sk    = creds.get("secret_key", "")
    else:
        # Shared secret: trilio-openstack-secret, keys <bt-name>_s3_*
        ak = decode(os_data.get(f"{name}_s3_access_key", ""))
        sk = decode(os_data.get(f"{name}_s3_secret_key", ""))

    if ak and sk:
        bt["access_key"] = ak
        bt["secret_key"] = sk
    else:
        missing.append(name)

if missing:
    print(f"[WARN] Credentials not found for: {missing}", file=sys.stderr)
    print("[WARN] These targets will fail in update_backup_targets_62.sh unless "
          "credentials are added manually to ${INVENTORY_FILE}", file=sys.stderr)

inventory["backup_targets"] = bts
with open("${INVENTORY_FILE}", "w") as f:
    yaml.dump(inventory, f, default_flow_style=False,
              allow_unicode=True, sort_keys=False)

os.remove("${CR_CREDS_FILE}")

found = len(s3_bts) - len(missing)
print(f"[INFO] Credentials collected for {found}/{len(s3_bts)} S3 backup target(s)")
PYEOF

log "Credentials written to ${INVENTORY_FILE}"

# -----------------------------------------------------------------------
# Step 5: Verify inventory against workloadmgr backup-target-list
# -----------------------------------------------------------------------
log_step "Step 5: Verify inventory against workloadmgr backup-target-list"

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
log_step "Step 6: Compare inventory vs workloadmgr"

python3 - <<PYEOF
import json, yaml, sys

with open("${INVENTORY_FILE}") as f:
    inventory = yaml.safe_load(f)

inv_bts = inventory.get("backup_targets", [])
# Compare S3 and NFS targets separately, using S3 bucket name or NFS share
# path as the identifier — target names may differ between
# tvo-operator-inputs.yaml/CRs and the WLM database.
inv_s3  = sorted(b["bucket"]     for b in inv_bts if b.get("type") == "s3"  and b.get("bucket"))
inv_nfs = sorted(b["nfs_shares"] for b in inv_bts if b.get("type") == "nfs" and b.get("nfs_shares"))

try:
    wlm_bts = json.loads(r"""${WLM_BT_JSON}""")
    # workloadmgr backup-target-list --format json returns the target type in
    # "Type" ("s3" or "nfs") and the bucket/endpoint in "Backend Endpoint".
    #   S3  Backend Endpoint: plain bucket name, or "host:port/bucket" —
    #       extract the last path component in both cases.
    #   NFS Backend Endpoint: the share path itself (e.g. "host:/export") —
    #       compare as-is; splitting on "/" would truncate it (this was the
    #       cause of the false "rhosp" mismatch from an NFS share ending in
    #       .../rhosp).
    wlm_s3 = sorted(
        (b.get("Backend Endpoint") or "").split("/")[-1]
        for b in wlm_bts
        if b.get("Backend Endpoint") and (b.get("Type") or "").lower() == "s3"
    )
    wlm_nfs = sorted(
        b.get("Backend Endpoint") or ""
        for b in wlm_bts
        if b.get("Backend Endpoint") and (b.get("Type") or "").lower() == "nfs"
    )
except Exception as exc:
    print(f"[WARN] Cannot parse workloadmgr output ({exc}). "
          "Verify manually: workloadmgr backup-target-list")
    sys.exit(0)

print(f"\n  Inventory S3 count    : {len(inv_s3)}")
print(f"  workloadmgr S3 count  : {len(wlm_s3)}")
print(f"  Inventory NFS count   : {len(inv_nfs)}")
print(f"  workloadmgr NFS count : {len(wlm_nfs)}")

mismatches = False

def report(label, only_inv, only_wlm):
    global mismatches
    if only_inv:
        print(f"\n[MISMATCH] {label} in inventory but not in workloadmgr:")
        for b in sorted(only_inv):
            print(f"  - {b}")
        mismatches = True
    if only_wlm:
        print(f"\n[MISMATCH] {label} in workloadmgr but not in inventory:")
        for b in sorted(only_wlm):
            print(f"  - {b}  <-- add to ${INVENTORY_FILE} before running "
                  "update_backup_targets_62.sh")
        mismatches = True

report("S3 buckets", set(inv_s3) - set(wlm_s3), set(wlm_s3) - set(inv_s3))
report("NFS shares", set(inv_nfs) - set(wlm_nfs), set(wlm_nfs) - set(inv_nfs))

if not mismatches:
    print("\n[OK] Inventory matches workloadmgr exactly.")
    print(f"     S3 buckets: {inv_s3}")
    print(f"     NFS shares: {inv_nfs}")
else:
    print("\n[ACTION] Correct ${INVENTORY_FILE} before running "
          "update_backup_targets_62.sh")
    sys.exit(1)
PYEOF

log_step "Done"
log "Inventory : ${INVENTORY_FILE}"
log "Next step : Review ${INVENTORY_FILE} then run update_backup_targets_62.sh"
