#!/usr/bin/env bash
# 03_create_workload_and_backup.sh
# Creates a TrilioVault workload for the test VM, takes a full backup snapshot,
# and captures all output and results to a timestamped file.
#
# What this script does:
#   1. Reads TEST_INSTANCE_ID from /tmp/trilio_test_resources.env
#      (written by 02_create_test_vm.sh)
#   2. Creates a workload with --manual schedule for the instance
#   3. Takes a full snapshot (backup) of the workload
#   4. Polls until the snapshot reaches 'available' or 'error'
#   5. Captures all workload and snapshot details to $RESULTS_FILE
#
# Doc reference: https://docs.trilio.io/openstack/t4o-6.x/user-guide/snapshots
#
# Usage:
#   bash 03_create_workload_and_backup.sh
#
# Verify results:
#   cat /tmp/trilio_backup_results_*.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Load instance ID saved by 02_create_test_vm.sh
RESOURCES_FILE="/tmp/trilio_test_resources.env"
if [[ ! -f "$RESOURCES_FILE" ]]; then
  echo "ERROR: $RESOURCES_FILE not found. Run 02_create_test_vm.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$RESOURCES_FILE"

if [[ -z "${TEST_INSTANCE_ID:-}" ]]; then
  echo "ERROR: TEST_INSTANCE_ID not set in $RESOURCES_FILE" >&2
  exit 1
fi

echo "OS_AUTH_URL:      $OS_AUTH_URL"
echo "TEST_INSTANCE_ID: $TEST_INSTANCE_ID"
echo "WORKLOAD_NAME:    $WORKLOAD_NAME"
echo "SNAPSHOT_NAME:    $SNAPSHOT_NAME"
echo "Results file:     $RESULTS_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

wlm_exec() {
  kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
    env OS_AUTH_URL="$OS_AUTH_URL" \
        OS_USERNAME="$OS_USERNAME" \
        OS_PASSWORD="$OS_PASSWORD" \
        OS_PROJECT_NAME="$OS_PROJECT_NAME" \
        OS_USER_DOMAIN_NAME="$OS_USER_DOMAIN_NAME" \
        OS_PROJECT_DOMAIN_NAME="$OS_PROJECT_DOMAIN_NAME" \
        OS_IDENTITY_API_VERSION="$OS_IDENTITY_API_VERSION" \
    workloadmgr "$@"
}

# log to both stdout and results file
tee_log() {
  tee -a "$RESULTS_FILE"
}

# ---------------------------------------------------------------------------
# Initialise results file
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$RESULTS_FILE")"
{
  echo "======================================================"
  echo "TrilioVault Backup Test Results"
  echo "Date:        $(date)"
  echo "Instance ID: $TEST_INSTANCE_ID"
  echo "Workload:    $WORKLOAD_NAME"
  echo "Snapshot:    $SNAPSHOT_NAME"
  echo "======================================================"
  echo ""
} > "$RESULTS_FILE"

# ---------------------------------------------------------------------------
# Step 1: Create workload
# Reference: https://docs.trilio.io/openstack/t4o-6.x/user-guide/workloads
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: Creating workload '$WORKLOAD_NAME' ===" | tee_log

WORKLOAD_JSON=$(wlm_exec workload-create \
  --instance "$TEST_INSTANCE_ID" \
  --display-name "$WORKLOAD_NAME" \
  --display-description "Automated test workload created by 03_create_workload_and_backup.sh" \
  --manual retention=30 \
  -f json 2>&1)

echo "$WORKLOAD_JSON" | tee_log
WORKLOAD_ID=$(echo "$WORKLOAD_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null \
  || echo "$WORKLOAD_JSON" | grep '"id"' | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')

echo ""
echo "  Workload ID: $WORKLOAD_ID" | tee_log

# Wait for workload to be 'available' (charm validates the instance exists)
echo "  Waiting for workload to become available..." | tee_log
for i in $(seq 1 20); do
  WL_STATUS=$(wlm_exec workload-show "$WORKLOAD_ID" -f value -c status 2>/dev/null)
  echo "  Workload status: $WL_STATUS" | tee_log
  if [[ "$WL_STATUS" == "available" ]]; then
    break
  elif [[ "$WL_STATUS" == "error" ]]; then
    echo "ERROR: Workload entered error state." | tee_log >&2
    wlm_exec workload-show "$WORKLOAD_ID" | tee_log
    exit 1
  fi
  sleep 10
done

echo ""
echo "  Workload details:" | tee_log
wlm_exec workload-show "$WORKLOAD_ID" | tee_log

# ---------------------------------------------------------------------------
# Step 2: Take full snapshot (backup)
# Reference: https://docs.trilio.io/openstack/t4o-6.x/user-guide/snapshots
# A snapshot is a point-in-time backup of all instances in the workload.
# --full forces a full backup regardless of schedule type.
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Taking full snapshot '$SNAPSHOT_NAME' ===" | tee_log

SNAPSHOT_JSON=$(wlm_exec workload-snapshot "$WORKLOAD_ID" \
  --full \
  --display-name "$SNAPSHOT_NAME" \
  --display-description "Full backup test — $(date)" \
  -f json 2>&1)

echo "$SNAPSHOT_JSON" | tee_log
SNAPSHOT_ID=$(echo "$SNAPSHOT_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null \
  || echo "$SNAPSHOT_JSON" | grep '"id"' | head -1 | sed 's/.*"id": "\([^"]*\)".*/\1/')

echo ""
echo "  Snapshot ID: $SNAPSHOT_ID" | tee_log

# ---------------------------------------------------------------------------
# Step 3: Poll until snapshot completes
# Snapshot lifecycle: creating → uploading → available (or error)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Polling snapshot status ===" | tee_log
echo "  (This may take several minutes — full backup uploads data to the backup target)"

POLL_INTERVAL=30
MAX_POLLS=60   # 30 minutes max

for i in $(seq 1 $MAX_POLLS); do
  SNAP_STATUS=$(wlm_exec snapshot-show "$SNAPSHOT_ID" -f value -c status 2>/dev/null || echo "unknown")
  SNAP_PROGRESS=$(wlm_exec snapshot-show "$SNAPSHOT_ID" -f value -c progress_percent 2>/dev/null || echo "0")
  echo "  [$(date +%H:%M:%S)] Snapshot status: $SNAP_STATUS  progress: ${SNAP_PROGRESS}%" | tee_log

  if [[ "$SNAP_STATUS" == "available" ]]; then
    echo "  Snapshot completed successfully." | tee_log
    break
  elif [[ "$SNAP_STATUS" == "error" ]]; then
    echo "ERROR: Snapshot entered error state." | tee_log >&2
    break
  fi
  sleep $POLL_INTERVAL
done

# ---------------------------------------------------------------------------
# Step 4: Capture final state
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Final state ===" | tee_log

echo ""
echo "--- Workload details ---" | tee_log
wlm_exec workload-show "$WORKLOAD_ID" | tee_log

echo ""
echo "--- Snapshot details ---" | tee_log
wlm_exec snapshot-show "$SNAPSHOT_ID" | tee_log

echo ""
echo "--- Snapshot list for workload ---" | tee_log
wlm_exec snapshot-list --workload-id "$WORKLOAD_ID" | tee_log

echo ""
echo "--- All workloads ---" | tee_log
wlm_exec workload-list | tee_log

echo ""
echo "--- Backup target list ---" | tee_log
wlm_exec backup-target-list | tee_log

# ---------------------------------------------------------------------------
# Result summary
# ---------------------------------------------------------------------------

FINAL_STATUS=$(wlm_exec snapshot-show "$SNAPSHOT_ID" -f value -c status 2>/dev/null || echo "unknown")

{
  echo ""
  echo "======================================================"
  echo "TEST RESULT SUMMARY"
  echo "======================================================"
  echo "Workload ID:  $WORKLOAD_ID"
  echo "Snapshot ID:  $SNAPSHOT_ID"
  echo "Final status: $FINAL_STATUS"
  if [[ "$FINAL_STATUS" == "available" ]]; then
    echo "RESULT: PASS — snapshot completed successfully"
  else
    echo "RESULT: FAIL — snapshot status: $FINAL_STATUS"
  fi
  echo "======================================================"
} | tee_log

echo ""
echo "Full results written to: $RESULTS_FILE"
