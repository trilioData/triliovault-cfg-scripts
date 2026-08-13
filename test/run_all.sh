#!/usr/bin/env bash
# run_all.sh — drive the whole T4O functional test in order.
#
# This suite tests an ALREADY-DEPLOYED T4O installation. It never builds
# artifacts and never deploys anything. If T4O is not installed, step 0 says so
# and stops rather than installing it.
#
# Order matters and is not arbitrary:
#
#   01 reachability   before anything is created, so a failed run changes nothing
#   02 licence
#   03 trust          backup-target-create needs the trust to already exist
#   04 targets
#   05 trustee roles
#   06 VMs + volumes
#   07 workloads + backups
#   08 report + conditional cleanup
#
# Usage:
#   bash run_all.sh                       # scope from T4O_BT_SCOPE (default both)
#   T4O_BT_SCOPE=s3 bash run_all.sh
#   T4O_BT_SCOPE=nfs T4O_NFS_TARGET=BT_NFS bash run_all.sh
#
# Step 01 exits 2 when a target is unreachable. That is a STOP, not a crash:
# nothing has been created, so fix the network, pick another target with
# T4O_S3_TARGET/T4O_NFS_TARGET, narrow T4O_BT_SCOPE, or walk away.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

run_step() {
    local script="$1"; shift
    printf '\n%s\n' "================================================================"
    printf '>>> %s\n' "$script"
    printf '%s\n' "================================================================"
    bash "$SCRIPT_DIR/$script" "$@"
    return $?
}

t4o_info "T4O functional test — scope: ${T4O_BT_SCOPE}"

# The gate. Its exit code is meaningful, so handle 2 distinctly from a crash.
run_step 01_check_backup_targets.sh
rc=$?
if [[ $rc -eq 2 ]]; then
    t4o_error "Stopped at the reachability gate. Nothing was created or modified."
    exit 2
elif [[ $rc -ne 0 ]]; then
    t4o_error "Reachability gate could not run (exit $rc)."
    exit $rc
fi

for step in 02_apply_license.sh 03_create_cloud_trust.sh \
            04_create_backup_targets.sh 05_verify_trustee_roles.sh \
            06_create_test_resources.sh; do
    if ! run_step "$step"; then
        t4o_error "$step failed — stopping before any workload is created."
        run_step 08_cleanup.sh --report-only
        exit 1
    fi
done

# Not guarded: 07 returns non-zero when a backup fails, and in `both` mode it
# still runs the second path. The report must record both outcomes, so let it
# finish and let 08 decide what that means.
run_step 07_workload_and_backup.sh
backup_rc=$?

run_step 08_cleanup.sh
cleanup_rc=$?

if [[ $backup_rc -ne 0 ]]; then
    t4o_error "At least one backup did not pass. Resources were left in place for inspection."
    exit 1
fi
exit $cleanup_rc
