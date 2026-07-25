#!/usr/bin/env bash
# 02_create_test_vm.sh
# Creates a test VM in OpenStack with a Cinder volume attached.
# Used to create the instance that will be backed up in 03_create_workload_and_backup.sh.
#
# What this script does:
#   1. Creates a VM (openstack server create) using image/flavor/network from env.sh
#   2. Creates a Cinder volume
#   3. Attaches the volume to the VM
#   4. Writes the instance ID and volume ID to /tmp/trilio_test_resources.env
#      so that 03_create_workload_and_backup.sh can pick them up.
#
# Usage:
#   bash 02_create_test_vm.sh
#
# Verify:
#   source /tmp/trilio_test_resources.env
#   openstack server show $TEST_INSTANCE_ID
#   openstack volume show $TEST_VOLUME_ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# All openstack CLI commands run inside the WLM pod because the openstack CLI
# there already has access to the internal Keystone endpoint, and we pass
# the admin credentials explicitly.
os_exec() {
  kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
    env OS_AUTH_URL="$OS_AUTH_URL" \
        OS_USERNAME="$OS_USERNAME" \
        OS_PASSWORD="$OS_PASSWORD" \
        OS_PROJECT_NAME="$OS_PROJECT_NAME" \
        OS_USER_DOMAIN_NAME="$OS_USER_DOMAIN_NAME" \
        OS_PROJECT_DOMAIN_NAME="$OS_PROJECT_DOMAIN_NAME" \
        OS_IDENTITY_API_VERSION="$OS_IDENTITY_API_VERSION" \
    openstack "$@"
}

echo "OS_AUTH_URL: $OS_AUTH_URL"
echo "Creating test VM: $TEST_VM_NAME"

# ---------------------------------------------------------------------------
# Step 1: Create VM
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: Creating VM '$TEST_VM_NAME' ==="
echo "  image=$TEST_IMAGE_NAME  flavor=$TEST_FLAVOR  network=$TEST_NETWORK"

INSTANCE_ID=$(os_exec server create \
  --image "$TEST_IMAGE_NAME" \
  --flavor "$TEST_FLAVOR" \
  --network "$TEST_NETWORK" \
  --wait \
  -f value -c id \
  "$TEST_VM_NAME")

echo "  Instance ID: $INSTANCE_ID"

# Wait for ACTIVE status
echo "  Waiting for instance to be ACTIVE..."
for i in $(seq 1 30); do
  STATUS=$(os_exec server show "$INSTANCE_ID" -f value -c status 2>/dev/null)
  echo "  Status: $STATUS"
  if [[ "$STATUS" == "ACTIVE" ]]; then
    break
  elif [[ "$STATUS" == "ERROR" ]]; then
    echo "ERROR: VM entered ERROR state." >&2
    os_exec server show "$INSTANCE_ID" >&2
    exit 1
  fi
  sleep 10
done

if [[ "$STATUS" != "ACTIVE" ]]; then
  echo "ERROR: VM did not reach ACTIVE within 5 minutes." >&2
  exit 1
fi

echo "  VM is ACTIVE."

# ---------------------------------------------------------------------------
# Step 2: Create Cinder volume
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Creating Cinder volume '$TEST_VOLUME_NAME' ==="
echo "  size=${TEST_VOLUME_SIZE}GB  type=$TEST_VOLUME_TYPE"

VOLUME_ID=$(os_exec volume create \
  --size "$TEST_VOLUME_SIZE" \
  --type "$TEST_VOLUME_TYPE" \
  -f value -c id \
  "$TEST_VOLUME_NAME")

echo "  Volume ID: $VOLUME_ID"

# Wait for volume to be available
echo "  Waiting for volume to become available..."
for i in $(seq 1 20); do
  VOL_STATUS=$(os_exec volume show "$VOLUME_ID" -f value -c status 2>/dev/null)
  echo "  Volume status: $VOL_STATUS"
  if [[ "$VOL_STATUS" == "available" ]]; then
    break
  elif [[ "$VOL_STATUS" == "error" ]]; then
    echo "ERROR: Volume entered error state." >&2
    exit 1
  fi
  sleep 5
done

if [[ "$VOL_STATUS" != "available" ]]; then
  echo "ERROR: Volume did not become available within 100 seconds." >&2
  exit 1
fi

echo "  Volume is available."

# ---------------------------------------------------------------------------
# Step 3: Attach volume to VM
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Attaching volume to VM ==="

os_exec server add volume "$INSTANCE_ID" "$VOLUME_ID"
echo "  Attach requested."

# Wait for volume to be in-use
echo "  Waiting for volume to be in-use..."
for i in $(seq 1 20); do
  VOL_STATUS=$(os_exec volume show "$VOLUME_ID" -f value -c status 2>/dev/null)
  echo "  Volume status: $VOL_STATUS"
  if [[ "$VOL_STATUS" == "in-use" ]]; then
    break
  fi
  sleep 5
done

if [[ "$VOL_STATUS" != "in-use" ]]; then
  echo "ERROR: Volume did not attach within 100 seconds." >&2
  exit 1
fi

echo "  Volume attached."

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo ""
echo "=== Verification ==="
os_exec server show "$INSTANCE_ID" -f table -c id -c name -c status -c volumes_attached
os_exec volume show "$VOLUME_ID"   -f table -c id -c name -c status -c size -c attachments

# ---------------------------------------------------------------------------
# Save resource IDs for next scripts
# ---------------------------------------------------------------------------

RESOURCES_FILE="/tmp/trilio_test_resources.env"
cat > "$RESOURCES_FILE" <<EOF
# Written by 02_create_test_vm.sh — sourced by 03_create_workload_and_backup.sh
export TEST_INSTANCE_ID="$INSTANCE_ID"
export TEST_VOLUME_ID="$VOLUME_ID"
EOF

echo ""
echo "=== Done ==="
echo "  Instance ID: $INSTANCE_ID"
echo "  Volume ID:   $VOLUME_ID"
echo "  Resource IDs saved to: $RESOURCES_FILE"
echo ""
echo "Next: bash 03_create_workload_and_backup.sh"
