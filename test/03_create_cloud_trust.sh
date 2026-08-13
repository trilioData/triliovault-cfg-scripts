#!/usr/bin/env bash
# 03_create_cloud_trust.sh — create the cloud admin trust.
#
# Trilio uses Keystone trusts so the WLM service user can act on behalf of the
# project owner during backup and restore. The cloud-level trust is created
# once, and backup-target creation depends on it existing.
#
#   https://docs.trilio.io/openstack/t4o-6.x/admin-guide/managing-trusts
#
# THE EXIT CODE IS NOT EVIDENCE. `workloadmgr trust-create` returns 0 even when
# wlm-api answers HTTP 500 — the cliff/cmd2 layer swallows it — so the charm
# actions that wrap it also report success on a failed call. The only proof is
# a non-empty `trust-list`, and that is what this script requires.
#
# Usage: bash 03_create_cloud_trust.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init

t4o_info ""
t4o_info "=== Step 3: Cloud admin trust ==="

trust_count() {
    # Count with -f value rather than by parsing the pretty table: trust IDs are
    # rendered as "trust-<uuid>", not a bare UUID, so a UUID-shaped row regex
    # silently matches nothing and reports "no trust" on a healthy deployment.
    wlm_exec trust-list -f value -c TrustID 2>/dev/null | t4o_denoise \
      | grep -c '[^[:space:]]' || true
}

existing=$(trust_count)
if [[ "${existing:-0}" -gt 0 ]]; then
    t4o_info "A cloud admin trust already exists ($existing row(s)); nothing to create."
    wlm_exec trust-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
    exit 0
fi

# The role is always `admin`, and the trust must be created by the same user
# and tenant that configured Trilio.
create_trust_cli() {
    # Mirrors kolla-ansible's create_cloud_trust.sh: 5 attempts, 30s apart,
    # retrying only while wlm-api is still coming up.
    local attempt out
    for attempt in 1 2 3 4 5; do
        t4o_info "  attempt $attempt/5..."
        out=$(wlm_exec trust-create --is_cloud_trust True admin 2>&1 | t4o_denoise)
        printf '%s\n' "$out" | sed 's/^/    /'
        if printf '%s' "$out" | grep -qi 'Service Unavailable'; then
            [[ $attempt -eq 5 ]] && break
            t4o_info "  wlm-api not ready yet; retrying in 30s"
            sleep 30
            continue
        fi
        break
    done
}

case "$T4O_DISTRO" in
  sunbeam)
    juju run trilio-wlm-k8s/leader create-cloud-admin-trust \
        password="$OS_PASSWORD" -m "$T4O_JUJU_K8S_MODEL" 2>&1 \
      | grep -v -i 'password' | sed 's/^/  /'
    ;;
  canonical)
    juju run trilio-wlm/leader create-cloud-admin-trust \
        password="$OS_PASSWORD" 2>&1 \
      | grep -v -i 'password' | sed 's/^/  /'
    ;;
  *)
    create_trust_cli
    ;;
esac

t4o_info ""
t4o_info "Verifying trust exists (trust-create exits 0 even on HTTP 500)..."
count=$(trust_count)
if [[ "${count:-0}" -gt 0 ]]; then
    wlm_exec trust-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
    t4o_info "Cloud admin trust present ($count row(s))."
    exit 0
fi

t4o_error "trust-list is empty — the trust was NOT created, whatever the command reported."
t4o_error ""
t4o_error "Most common cause: the WLM 'job' table is missing its audit columns"
t4o_error "(created_at/updated_at/deleted_at/deleted/version/progress), so every"
t4o_error "job-creating API call fails with:"
t4o_error "  (pymysql.err.OperationalError) (1054, \"Unknown column 'created_at' in 'field list'\")"
t4o_error "The WLM service still reports healthy — only job-creating calls fail."
t4o_error "Fix is alembic migration 030 in the WLM image."
t4o_error ""
t4o_error "Recent WLM log:"
wlm_logs 40 | sed 's/^/  /'
exit 1
