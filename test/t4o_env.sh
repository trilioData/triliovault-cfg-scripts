#!/usr/bin/env bash
# t4o_env.sh — Shared configuration for the T4O functional test suite
#
# Source this file at the top of each test script:
#   source "$(dirname "$0")/t4o_env.sh"
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
OS_PASSWORD=$(juju run keystone/leader get-admin-account -m controller0/openstack 2>/dev/null \
  | grep '^password:' | awk '{print $2}')

if [[ -z "$OS_PASSWORD" ]]; then
  echo "ERROR: Could not fetch admin password via 'juju run keystone/leader get-admin-account -m controller0/openstack'." >&2
  exit 1
fi

export OS_USERNAME="admin"
export OS_PROJECT_NAME="admin"
export OS_USER_DOMAIN_NAME="admin_domain"
export OS_PROJECT_DOMAIN_NAME="admin_domain"
export OS_IDENTITY_API_VERSION="3"

# Backup target config (endpoints, buckets, credentials, NFS path) is loaded
# from <workspace-root>/env/backup_targets.yaml by 04_create_backup_targets.sh.
# DMS secret payloads are stored in Barbican (deployed by Sunbeam).

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
