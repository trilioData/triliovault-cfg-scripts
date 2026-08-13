#!/usr/bin/env bash
# 05_verify_trustee_roles.sh — ensure the test user holds every trustee role.
#
# `trustee_role` in the live WLM config lists the role(s) Trilio delegates in
# the per-tenant trust it creates for each workload. If the user creating the
# workload does not actually hold those roles, workload creation fails in a way
# that points at the trust rather than at the missing role assignment.
#
# The default differs per distro and is genuinely inconsistent across the repo
# (creator / member / _member_ / comma lists), so this reads the LIVE value
# rather than assuming one.
#
# This step MODIFIES Keystone: it grants any missing role to the test user.
# That is deliberate — it is a prerequisite for the backup to work — and every
# grant is reported.
#
# Usage: bash 05_verify_trustee_roles.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init

t4o_info ""
t4o_info "=== Step 5: Trustee roles ==="

raw_roles="$(wlm_conf trustee_role)"
if [[ -z "$raw_roles" ]]; then
    t4o_warn "trustee_role is not set in $T4O_WLM_CONF — nothing to verify."
    exit 0
fi
t4o_info "Live trustee_role from WLM config: [$raw_roles]"

# Split on commas and trim. Note some deployments render this key with a
# trailing space in the NAME (an openstack-helm templating bug); reading the
# value is unaffected, but do not assume the list is clean.
IFS=',' read -r -a ROLES <<< "$raw_roles"

assigned="$(os_exec role assignment list --user "$OS_USERNAME" \
              --project "$OS_PROJECT_NAME" --names -f value -c Role 2>/dev/null | t4o_denoise)"
t4o_info "Roles currently held by $OS_USERNAME on project $OS_PROJECT_NAME: $(echo "$assigned" | tr '\n' ' ')"

missing=0 added=0
for r in "${ROLES[@]}"; do
    role="$(printf '%s' "$r" | xargs)"      # trim
    [[ -z "$role" ]] && continue

    if printf '%s\n' "$assigned" | grep -qx "$role"; then
        t4o_info "  OK      $role"
        continue
    fi

    missing=$((missing+1))
    t4o_info "  MISSING $role — granting"
    if os_exec role add --project "$OS_PROJECT_NAME" --user "$OS_USERNAME" "$role" 2>&1 | t4o_denoise | sed 's/^/    /'; then
        added=$((added+1))
    else
        t4o_error "  failed to grant '$role' — does the role exist in Keystone?"
    fi
done

if [[ $missing -gt 0 ]]; then
    t4o_info ""
    t4o_info "Re-checking after granting..."
    assigned="$(os_exec role assignment list --user "$OS_USERNAME" \
                  --project "$OS_PROJECT_NAME" --names -f value -c Role 2>/dev/null | t4o_denoise)"
    for r in "${ROLES[@]}"; do
        role="$(printf '%s' "$r" | xargs)"; [[ -z "$role" ]] && continue
        if printf '%s\n' "$assigned" | grep -qx "$role"; then
            t4o_info "  OK      $role"
        else
            t4o_error "  STILL MISSING $role"
            exit 1
        fi
    done
fi

t4o_info ""
if [[ $added -gt 0 ]]; then
    t4o_info "Trustee roles satisfied ($added granted this run)."
else
    t4o_info "Trustee roles satisfied (no changes needed)."
fi
exit 0
