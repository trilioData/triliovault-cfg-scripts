#!/usr/bin/env bash
# 02_apply_license.sh — apply the T4O licence.
#
# Runs after the reachability gate, because there is no point licensing a
# deployment whose backup target was never going to work.
#
# Two mechanics that are easy to get wrong and are handled here:
#   --accept-eula is REQUIRED. Without it license-create blocks forever on a
#   curses EULA prompt (the flag was added in workloadmgrclient for TVAULT-7518).
#
#   For `juju attach-resource`, the licence file must have NO extension. Juju
#   validates the filename against the resource definition, which expects an
#   empty extension, so license_trilio.txt is copied to a file named `license`.
#
# Verification is by `license-list`, never by exit code.
#
# Usage: bash 02_apply_license.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init

LICENSE_SRC="${TRILIO_ENV_DIR}/license_trilio.txt"
[[ -f "$LICENSE_SRC" ]] || t4o_die "Licence file not found: $LICENSE_SRC"

t4o_info ""
t4o_info "=== Step 2: Apply T4O licence ==="

license_is_valid() {
    wlm_exec license-list 2>/dev/null | t4o_denoise | grep -qiE 'value|expir|licen'
}

# WLM stamps the EULA acceptance time when a licence is applied, so this value
# changes on every successful apply — including a re-apply of the same file.
# It is the only way to tell "this run applied a licence" from "a licence was
# already here", and without that distinction a failed apply passes silently
# whenever any earlier licence exists. Resolution is one minute, so two applies
# inside the same minute would look identical; the action's own exit status is
# what actually gates the result below, and this is the corroborating check.
license_stamp() {
    wlm_exec license-list 2>/dev/null | t4o_denoise \
      | grep -oE '"agreed_time":[^,]*' | head -1
}

STAMP_BEFORE=""
if license_is_valid; then
    t4o_info "A licence is already present:"
    wlm_exec license-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
    STAMP_BEFORE=$(license_stamp)
    t4o_info "Re-applying anyway so the run tests the current licence file."
fi

# The file must have no extension for the Juju resource path; use the same
# bare name everywhere so the two code paths cannot drift.
STAGED="${T4O_WORK_DIR}/license"
cp -f "$LICENSE_SRC" "$STAGED"

# All the per-distro mechanics, including the rollout `juju attach-resource`
# triggers on Sunbeam, live in apply_license() in t4o_env.sh.
if ! apply_license "$STAGED"; then
    t4o_error "The licence apply step reported failure."
    t4o_error "Check the WLM API log:"
    wlm_logs 40 | sed 's/^/  /'
    exit 1
fi

t4o_info ""
t4o_info "Verifying licence (the CLI's exit code is not evidence)..."
if ! license_is_valid; then
    t4o_error "No valid licence found after apply."
    t4o_error "Check the WLM API log for the failure:"
    wlm_logs 40 | sed 's/^/  /'
    exit 1
fi

# A licence being present is not proof this run applied one — see license_stamp.
STAMP_AFTER=$(license_stamp)
if [[ -n "$STAMP_BEFORE" && "$STAMP_AFTER" == "$STAMP_BEFORE" ]]; then
    t4o_error "A licence is present, but its EULA timestamp is unchanged ($STAMP_AFTER)."
    t4o_error "That is the licence that was already here; this run applied nothing."
    wlm_logs 40 | sed 's/^/  /'
    exit 1
fi

wlm_exec license-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
t4o_info "Licence applied."
exit 0
