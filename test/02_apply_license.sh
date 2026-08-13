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

if license_is_valid; then
    t4o_info "A licence is already present:"
    wlm_exec license-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
    t4o_info "Re-applying anyway so the run tests the current licence file."
fi

# The file must have no extension for the Juju resource path; use the same
# bare name everywhere so the two code paths cannot drift.
STAGED="${T4O_WORK_DIR}/license"
cp -f "$LICENSE_SRC" "$STAGED"

case "$T4O_DISTRO" in
  sunbeam)
    copy_to_wlm "$STAGED" /tmp/license
    juju run trilio-wlm-k8s/leader create-license \
        license-file-path=/tmp/license -m "$T4O_JUJU_K8S_MODEL" 2>&1 | sed 's/^/  /'
    ;;
  canonical)
    juju attach-resource trilio-wlm "license=$STAGED" 2>&1 | sed 's/^/  /'
    juju run trilio-wlm/leader create-license 2>&1 | sed 's/^/  /'
    ;;
  *)
    copy_to_wlm "$STAGED" /tmp/license
    wlm_exec license-create /tmp/license --accept-eula 2>&1 | t4o_denoise | sed 's/^/  /'
    ;;
esac

t4o_info ""
t4o_info "Verifying licence (the CLI's exit code is not evidence)..."
if license_is_valid; then
    wlm_exec license-list 2>/dev/null | t4o_denoise | sed 's/^/  /'
    t4o_info "Licence applied."
    exit 0
fi

t4o_error "No valid licence found after apply."
t4o_error "Check the WLM API log for the failure:"
wlm_logs 40 | sed 's/^/  /'
exit 1
