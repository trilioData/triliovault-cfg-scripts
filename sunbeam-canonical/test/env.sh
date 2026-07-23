#!/usr/bin/env bash
# env.sh — Shared configuration for Sunbeam T4O test scripts
#
# Source this file at the top of each test script:
#   source "$(dirname "$0")/env.sh"
#
# OpenStack admin credentials are fetched automatically from the Sunbeam
# Juju charm (keystone/leader) and the WLM pod config — no hardcoded values.

# ---------------------------------------------------------------------------
# WLM pod details (Sunbeam MicroK8s)
# ---------------------------------------------------------------------------
export WLM_POD="trilio-wlm-k8s-0"
export WLM_CONTAINER="trilio-wlm"
export K8S_NAMESPACE="openstack"

# ---------------------------------------------------------------------------
# Discover OpenStack admin credentials from the installed charm
#
# auth_url: read from the WLM pod's config — always reflects the current
#   Keystone ClusterIP set by the charm at deploy/upgrade time.
# admin password: fetched from the keystone leader Juju action.
# Domain/project names: Sunbeam convention (admin_domain / admin).
# ---------------------------------------------------------------------------
export OS_AUTH_URL
OS_AUTH_URL=$(kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" \
  -- grep '^auth_url' /etc/triliovault-wlm/triliovault-wlm.conf \
  | awk '{print $3}')

if [[ -z "$OS_AUTH_URL" ]]; then
  echo "ERROR: Could not read auth_url from WLM pod config. Is the WLM charm deployed?" >&2
  exit 1
fi

export OS_PASSWORD
OS_PASSWORD=$(juju run keystone/leader get-admin-password 2>/dev/null \
  | grep '^password:' | awk '{print $2}')

if [[ -z "$OS_PASSWORD" ]]; then
  echo "ERROR: Could not fetch admin password via 'juju run keystone/leader get-admin-password'." >&2
  exit 1
fi

export OS_USERNAME="admin"
export OS_PROJECT_NAME="admin"
export OS_USER_DOMAIN_NAME="admin_domain"
export OS_PROJECT_DOMAIN_NAME="admin_domain"
export OS_IDENTITY_API_VERSION="3"

# ---------------------------------------------------------------------------
# S3 backup target credentials — must be provided as environment variables.
# Export these before sourcing env.sh, or pass inline:
#   BT1_S3_ACCESS_KEY=... BT2_S3_ACCESS_KEY=... source env.sh
# ---------------------------------------------------------------------------
export BT1_S3_ACCESS_KEY="${BT1_S3_ACCESS_KEY:-}"
export BT1_S3_SECRET_KEY="${BT1_S3_SECRET_KEY:-}"
export BT2_S3_ACCESS_KEY="${BT2_S3_ACCESS_KEY:-}"
export BT2_S3_SECRET_KEY="${BT2_S3_SECRET_KEY:-}"

# ---------------------------------------------------------------------------
# NFS backup target
# ---------------------------------------------------------------------------
export NFS_TARGET_NAME="BT_NFS"
export NFS_SERVER_EXPORT="${NFS_SERVER_EXPORT:-192.168.1.100:/backup}"
export NFS_MOUNT_OPTS="nolock,soft,timeo=600,intr,lookupcache=none,nfsvers=3,retrans=10"

# ---------------------------------------------------------------------------
# Secret-server (Barbican replacement for Sunbeam)
# ---------------------------------------------------------------------------
export SECRET_SERVER_PORT="8765"
export SECRET_SERVER_SVC="trilio-secret-server"

# ---------------------------------------------------------------------------
# Test VM settings
# ---------------------------------------------------------------------------
export TEST_VM_NAME="trilio-test-vm"
export TEST_IMAGE_NAME="ubuntu"
export TEST_FLAVOR="m1.tiny"
export TEST_NETWORK="demo-network"
export TEST_VOLUME_NAME="trilio-test-vol"
export TEST_VOLUME_SIZE="5"
export TEST_VOLUME_TYPE="__DEFAULT__"

# ---------------------------------------------------------------------------
# Workload / backup settings
# ---------------------------------------------------------------------------
export WORKLOAD_NAME="trilio-test-workload"
export SNAPSHOT_NAME="trilio-test-snapshot-1"
export RESULTS_FILE="/tmp/trilio_backup_results_$(date +%Y%m%d_%H%M%S).txt"
