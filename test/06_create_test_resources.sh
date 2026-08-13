#!/usr/bin/env bash
# 06_create_test_resources.sh — create the test VM(s) and their volumes.
#
# ONE VM PER SELECTED BACKUP TARGET: one for s3 or nfs, two for both. Each
# target gets its own workload, so in `both` mode the two backups exercise
# genuinely independent data paths.
#
# Names stay role-suffixed even in single-target mode (trilio-test-vm-s3,
# trilio-test-vm-nfs) so a later run against the other target cannot collide
# with leftovers from this one.
#
# Every created ID is written to $T4O_RESOURCES_FILE. Cleanup only ever touches
# what is recorded there, so resources created by anyone else — including an
# earlier run of this suite — are never removed.
#
# Usage: bash 06_create_test_resources.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

t4o_init

t4o_info ""
t4o_info "=== Step 6: Test VMs and volumes (scope: $T4O_BT_SCOPE) ==="

ROLES=()
t4o_scope_includes s3  && ROLES+=("s3")
t4o_scope_includes nfs && ROLES+=("nfs")

# ---------------------------------------------------------------------------
# What this cloud actually offers
#
# Enumerated, never hardcoded — this is what covers "ceph, iscsi" and anything
# else without assuming a particular backend is present.
# ---------------------------------------------------------------------------
# T4O_SKIP_VOLUMES=1 boots the VM(s) from image with no volumes attached.
#
# Use it to isolate a failure: if a volumeless backup passes while a
# volume-backed one fails, the fault is in the block-storage path (the
# DataMover's Ceph/iSCSI access), not in WLM, the trust, or the target.
# It is NOT the default — a backup that never touches a volume tests less.
if [[ "${T4O_SKIP_VOLUMES:-0}" == "1" ]]; then
    t4o_warn "T4O_SKIP_VOLUMES=1 — booting from image only."
    t4o_warn "This does NOT exercise the block-storage path; treat a pass accordingly."
    VOLUME_TYPES=()
else
    mapfile -t VOLUME_TYPES < <(os_exec volume type list -f value -c Name 2>/dev/null | t4o_denoise | grep -v '^$')
fi
if [[ "${T4O_SKIP_VOLUMES:-0}" == "1" ]]; then
    :   # already warned above; nothing to enumerate
elif [[ ${#VOLUME_TYPES[@]} -eq 0 ]]; then
    t4o_warn "No Cinder volume types found — VMs will be created without volumes."
else
    t4o_info "Volume types offered by this cloud: ${VOLUME_TYPES[*]}"
    if [[ ${#VOLUME_TYPES[@]} -eq 1 ]]; then
        t4o_info "  (only one type — multi-backend coverage is NOT exercised on this cloud)"
    fi
fi

# ---------------------------------------------------------------------------
# Quota guard
#
# Trilio needs, per disk backed up, 1 extra Cinder volume and 2 Cinder
# snapshots. Insufficient quota is a documented and silent cause of snapshot
# failure, so check before booting anything rather than 20 minutes into a backup.
# ---------------------------------------------------------------------------
need_volumes=$(( ${#ROLES[@]} * ${#VOLUME_TYPES[@]} ))
if [[ $need_volumes -gt 0 ]]; then
    quota_vol=$(os_exec quota show -f value -c volumes 2>/dev/null | t4o_denoise | head -1)
    used_vol=$(os_exec volume list -f value -c ID 2>/dev/null | t4o_denoise | grep -c '[^[:space:]]' || true)
    if [[ "$quota_vol" =~ ^[0-9]+$ ]] && [[ "$quota_vol" -ge 0 ]]; then
        # Trilio itself will want another volume per disk during the snapshot.
        want=$(( used_vol + need_volumes * 2 ))
        if [[ "$quota_vol" -ne -1 && $want -gt $quota_vol ]]; then
            t4o_warn "Cinder volume quota may be too low: $used_vol in use, this run adds $need_volumes,"
            t4o_warn "and Trilio needs roughly one more per disk during the snapshot (~$want vs quota $quota_vol)."
        fi
    fi
fi

# resources.env accumulates across the steps; start it fresh here since this is
# the step that creates the things cleanup will remove.
: > "$T4O_RESOURCES_FILE"
echo "T4O_BT_SCOPE='$T4O_BT_SCOPE'" >> "$T4O_RESOURCES_FILE"

poll_until() {                 # <desc> <tries> <sleep> <cmd...> -- expects cmd to echo the state
    local desc="$1" tries="$2" nap="$3"; shift 3
    local i state
    for ((i=1; i<=tries; i++)); do
        state="$("$@" 2>/dev/null | t4o_denoise | tr -d '\r' | head -1)"
        printf '    %s: %s\n' "$desc" "${state:-?}"
        case "$state" in
          ACTIVE|available|in-use) echo "$state"; return 0 ;;
          ERROR|error)             echo "$state"; return 1 ;;
        esac
        sleep "$nap"
    done
    echo "${state:-timeout}"; return 1
}

server_status() { os_exec server show "$1" -f value -c status; }
volume_status() { os_exec volume show "$1" -f value -c status; }

for role in "${ROLES[@]}"; do
    vm_name="$(t4o_vm_name "$role")"
    t4o_info ""
    t4o_info "--- $role: VM $vm_name ---"

    existing_id="$(os_exec server list --name "^${vm_name}$" -f value -c ID 2>/dev/null | t4o_denoise | head -1)"
    if [[ -n "$existing_id" ]]; then
        t4o_die "A VM named '$vm_name' already exists ($existing_id).
  This suite will not adopt a VM it did not create, because cleanup would then
  delete something that is not ours. Remove it first, or run with a different
  scope. Leftovers from a previous run are safe to delete by hand."
    fi

    instance_id="$(os_exec server create \
        --image "$TEST_IMAGE_NAME" --flavor "$TEST_FLAVOR" --network "$TEST_NETWORK" \
        --wait -f value -c id "$vm_name" 2>&1 | t4o_denoise | tail -1)"
    if [[ ! "$instance_id" =~ ^[0-9a-f-]{36}$ ]]; then
        t4o_die "server create did not return an instance ID: $instance_id"
    fi
    t4o_info "  instance: $instance_id"
    echo "$(echo "$role" | tr a-z A-Z)_INSTANCE_ID='$instance_id'" >> "$T4O_RESOURCES_FILE"

    if ! poll_until "server" 30 10 server_status "$instance_id" >/dev/null; then
        os_exec server show "$instance_id" | sed 's/^/    /'
        t4o_die "VM $vm_name did not reach ACTIVE."
    fi
    t4o_info "  VM is ACTIVE"

    vol_ids=()
    for vtype in "${VOLUME_TYPES[@]}"; do
        vol_name="$(t4o_volume_name "$role" "$vtype")"
        t4o_info "  volume $vol_name (type $vtype, ${TEST_VOLUME_SIZE}GB)"
        vol_id="$(os_exec volume create --size "$TEST_VOLUME_SIZE" --type "$vtype" \
                    -f value -c id "$vol_name" 2>&1 | t4o_denoise | tail -1)"
        if [[ ! "$vol_id" =~ ^[0-9a-f-]{36}$ ]]; then
            t4o_error "  volume create failed for type '$vtype': $vol_id"
            continue
        fi
        if ! poll_until "volume" 24 5 volume_status "$vol_id" >/dev/null; then
            t4o_error "  volume $vol_id never became available; skipping attach"
            continue
        fi
        os_exec server add volume "$instance_id" "$vol_id" >/dev/null 2>&1
        if poll_until "attach" 24 5 volume_status "$vol_id" >/dev/null; then
            t4o_info "    attached"
            vol_ids+=("$vol_id")
        else
            t4o_error "  volume $vol_id did not reach in-use"
        fi
    done

    echo "$(echo "$role" | tr a-z A-Z)_VOLUME_IDS='${vol_ids[*]}'" >> "$T4O_RESOURCES_FILE"
    t4o_info "  volumes attached: ${#vol_ids[@]}"
done

t4o_info ""
t4o_info "Resources recorded in $T4O_RESOURCES_FILE:"
sed 's/^/  /' "$T4O_RESOURCES_FILE"
exit 0
