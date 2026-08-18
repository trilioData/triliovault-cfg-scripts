#!/usr/bin/env bash
# 07_workload_and_backup.sh — create a workload per selected target and back it up.
#
# One workload per selected backup target, each pinned to its own target:
#
#   trilio-test-workload-s3   -> trilio-test-vm-s3   -> the S3 target
#   trilio-test-workload-nfs  -> trilio-test-vm-nfs  -> the NFS target
#
# The backup target type is IMMUTABLE after workload creation, which is why
# each target needs its own workload rather than one workload retargeted twice.
#
# In `both` mode the two backups run sequentially and THE SECOND RUNS EVEN IF
# THE FIRST FAILS. Knowing that S3 works while NFS does not (or the reverse) is
# the single most useful diagnostic this suite produces, so one failure must not
# short-circuit the other path.
#
# Usage: bash 07_workload_and_backup.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init

[[ -f "$T4O_RESOURCES_FILE" ]] || t4o_die "No resources file at $T4O_RESOURCES_FILE — run 06_create_test_resources.sh first."
# shellcheck disable=SC1090
source "$T4O_RESOURCES_FILE"

BT_ENV="${T4O_WORK_DIR}/backup_targets.env"
[[ -f "$BT_ENV" ]] || t4o_die "No backup target record at $BT_ENV — run 04_create_backup_targets.sh first."
# shellcheck disable=SC1090
source "$BT_ENV"

t4o_info ""
t4o_info "=== Step 7: Workloads and backups (scope: $T4O_BT_SCOPE) ==="

POLL_INTERVAL="${T4O_SNAPSHOT_POLL_INTERVAL:-30}"
MAX_POLLS="${T4O_SNAPSHOT_MAX_POLLS:-60}"      # 30 minutes at the default interval

RESULTS_FILE="${T4O_WORK_DIR}/backup_results.env"
: > "$RESULTS_FILE"

# The workloadmgr CLI is inconsistent about column naming, and getting it wrong
# fails the command outright rather than returning something odd:
#
#   workload-create / workload-snapshot   table view,  columns 'ID','Name','Status'
#   workload-show   / snapshot-show       detail view, fields  'id','status',...
#
# Rather than encode that per command, ask for the capitalised column and fall
# back to pulling the first UUID out of the plain output.
#
# Pass every UUID the caller already knows as $2.. so they can be excluded. On
# SUCCESS the output holds only the new object's UUID, but on FAILURE workloadmgr
# echoes the arguments back in its error text - so `workload-create --instance
# <uuid>` failing with "Unencrypted workload cannot have instance <uuid> with
# encrypted Volume <uuid>" made this return the INSTANCE id, which the caller
# then stored as the workload id and polled for 15 minutes ("workload never
# became available") instead of reporting the HTTP 400 it was handed.
_id_from() {
    local out="$1"; shift
    local ids id
    ids="$(printf '%s' "$out" | tr -d '\r' | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')"
    for known in "$@"; do
        [[ -n "$known" ]] && ids="$(printf '%s\n' "$ids" | grep -vixF "$known")"
    done
    id="$(printf '%s\n' "$ids" | grep -v '^$' | head -1)"
    printf '%s' "$id"
}

run_one() {
    local role="$1" btt="$2" instance_id="$3"
    local wl_name snap_name workload_id snapshot_id status progress

    wl_name="$(t4o_workload_name "$role")"
    snap_name="$(t4o_snapshot_name "$role")"

    t4o_info ""
    t4o_info "--- $role: workload '$wl_name' on backup target type '$btt' ---"

    if [[ -z "$instance_id" ]]; then
        t4o_error "  no instance recorded for role '$role' — skipping"
        echo "${role^^}_RESULT='NO_INSTANCE'" >> "$RESULTS_FILE"
        return 1
    fi

    # Adopt an existing workload of OUR name rather than failing.
    #
    # An instance can belong to only one workload, so a re-run after any hiccup
    # between "the API created it" and "we recorded the ID" would otherwise die
    # with "Invalid instance as <vm> already attached with other workload" and
    # leave the first workload orphaned. The name is ours by convention
    # (trilio-test-workload-<role>), so reusing it is safe and makes re-runs
    # idempotent.
    local existing_wl
    existing_wl="$(wlm_exec workload-list -f value -c ID -c Name 2>/dev/null | t4o_denoise \
                   | awk -v n="$wl_name" '$2==n {print $1; exit}')"
    if [[ -n "$existing_wl" ]]; then
        t4o_info "  reusing existing workload $existing_wl ('$wl_name')"
        workload_id="$existing_wl"
        echo "${role^^}_WORKLOAD_ID='$workload_id'" >> "$T4O_RESOURCES_FILE"
    else

    # --instance takes a BARE UUID. The docs' "instance-id=<uuid>" form is the
    # positional argument syntax; passing it to the flag fails with
    # "badly formed hexadecimal UUID string".
    local out
    out="$(wlm_exec workload-create \
        --instance "$instance_id" \
        --display-name "$wl_name" \
        --display-description "t4o-test functional run ($role)" \
        --backup-target-type "$btt" \
        --manual retention=30 2>&1 | t4o_denoise)"
    workload_id="$(_id_from "$out" "$instance_id")"

    if [[ -z "$workload_id" ]]; then
        t4o_error "  workload-create failed:"
        printf '%s\n' "$out" | sed 's/^/    /'
        echo "${role^^}_RESULT='WORKLOAD_CREATE_FAILED'" >> "$RESULTS_FILE"
        return 1
    fi
    t4o_info "  workload: $workload_id"
    echo "${role^^}_WORKLOAD_ID='$workload_id'" >> "$T4O_RESOURCES_FILE"
    fi

    local i
    for ((i=1; i<=20; i++)); do
        status="$(wlm_exec workload-show "$workload_id" -f value -c status 2>/dev/null | t4o_denoise | tr -d '\r' | head -1)"
        t4o_info "    workload status: ${status:-?}"
        [[ "$status" == "available" ]] && break
        if [[ "$status" == "error" ]]; then
            wlm_exec workload-show "$workload_id" 2>&1 | t4o_denoise | sed 's/^/    /'
            echo "${role^^}_RESULT='WORKLOAD_ERROR'" >> "$RESULTS_FILE"
            return 1
        fi
        sleep 10
    done
    [[ "$status" == "available" ]] || { t4o_error "  workload never became available"; \
        echo "${role^^}_RESULT='WORKLOAD_TIMEOUT'" >> "$RESULTS_FILE"; return 1; }

    out="$(wlm_exec workload-snapshot "$workload_id" --full \
        --display-name "$snap_name" \
        --display-description "t4o-test full backup ($role)" 2>&1 | t4o_denoise)"
    # The workload UUID appears in this output too, so take the one that is not
    # the workload we just created.
    snapshot_id="$(printf '%s' "$out" | tr -d '\r' \
        | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | grep -v "^${workload_id}$" | head -1)"

    if [[ -z "$snapshot_id" ]]; then
        t4o_error "  workload-snapshot failed:"
        printf '%s\n' "$out" | sed 's/^/    /'
        echo "${role^^}_RESULT='SNAPSHOT_CREATE_FAILED'" >> "$RESULTS_FILE"
        return 1
    fi
    t4o_info "  snapshot: $snapshot_id"
    echo "${role^^}_SNAPSHOT_ID='$snapshot_id'" >> "$T4O_RESOURCES_FILE"

    t4o_info "  polling (creating -> uploading -> available); up to $((POLL_INTERVAL*MAX_POLLS/60)) minutes"
    for ((i=1; i<=MAX_POLLS; i++)); do
        # Poll via snapshot-LIST, not snapshot-show. snapshot-show emits TWO
        # tables — an Instances table, then the Field/Value detail — so
        # "-f value -c status" is ambiguous and returns table borders rather
        # than a status. snapshot-list is a single clean table.
        status="$(wlm_exec snapshot-list -f value -c ID -c Status 2>/dev/null | t4o_denoise \
                  | awk -v s="$snapshot_id" '$1==s {print $2; exit}')"
        printf '    [%s] %s\n' "$(date +%H:%M:%S)" "${status:-?}"
        case "$status" in
          available)
            t4o_info "  BACKUP PASSED ($role)"
            echo "${role^^}_RESULT='PASS'"           >> "$RESULTS_FILE"
            echo "${role^^}_SNAPSHOT_ID='$snapshot_id'" >> "$RESULTS_FILE"
            return 0 ;;
          error)
            t4o_error "  BACKUP FAILED ($role)"
            # error_msg and warning_msg are the two fields worth reading first;
            # the rest of snapshot-show is noise at this point.
            wlm_exec snapshot-show "$snapshot_id" 2>/dev/null | t4o_denoise \
              | grep -iE 'error_msg|warning_msg|host|time_taken' | sed 's/^/    /'
            echo "${role^^}_RESULT='FAIL'"           >> "$RESULTS_FILE"
            echo "${role^^}_SNAPSHOT_ID='$snapshot_id'" >> "$RESULTS_FILE"
            return 1 ;;
        esac
        sleep "$POLL_INTERVAL"
    done

    t4o_error "  BACKUP TIMED OUT ($role) after $((POLL_INTERVAL*MAX_POLLS/60)) minutes"
    echo "${role^^}_RESULT='TIMEOUT'" >> "$RESULTS_FILE"
    echo "${role^^}_SNAPSHOT_ID='$snapshot_id'" >> "$RESULTS_FILE"
    return 1
}

overall=0

if t4o_scope_includes s3; then
    run_one s3 "${BT_S3_BTT_NAME:-}" "${S3_INSTANCE_ID:-}" || overall=1
fi

# Deliberately NOT short-circuited on the first failure.
if t4o_scope_includes nfs; then
    run_one nfs "${BT_NFS_BTT_NAME:-}" "${NFS_INSTANCE_ID:-}" || overall=1
fi

t4o_info ""
t4o_info "=== Backup results ==="
sed 's/^/  /' "$RESULTS_FILE"
exit $overall
