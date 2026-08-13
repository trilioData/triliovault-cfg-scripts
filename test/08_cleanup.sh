#!/usr/bin/env bash
# 08_cleanup.sh — write the run report, then clean up conditionally.
#
#   every tested backup PASSED -> delete the snapshots, workloads, VMs and
#                                 volumes THIS RUN created
#   any tested backup FAILED   -> delete nothing, so the state can be inspected
#
# Backup targets are NEVER deleted. They are shared infrastructure defined in
# backup_targets.yaml, not per-run resources.
#
# Cleanup only ever touches IDs recorded in $T4O_RESOURCES_FILE by this run. A
# VM or workload left behind by an earlier run — against the other target, or by
# someone else — is never removed.
#
# The generated openrc is removed either way: this suite does not add another
# place where a cloud admin credential persists.
#
# Usage:
#   bash 08_cleanup.sh              # report + conditional cleanup
#   bash 08_cleanup.sh --report-only
#   bash 08_cleanup.sh --force      # clean up even after a failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

MODE="${1:-}"

t4o_init

RESULTS_FILE="${T4O_WORK_DIR}/backup_results.env"
BT_ENV="${T4O_WORK_DIR}/backup_targets.env"
MATRIX_FILE="${T4O_WORK_DIR}/reachability_matrix.txt"

[[ -f "$T4O_RESOURCES_FILE" ]] && { . "$T4O_RESOURCES_FILE"; }
[[ -f "$RESULTS_FILE"       ]] && { . "$RESULTS_FILE"; }
[[ -f "$BT_ENV"             ]] && { . "$BT_ENV"; }

STAMP="$(date -u +%Y-%m-%d)"
SETUP_LABEL="${T4O_SETUP_NAME:-$T4O_DISTRO}"
REPORT="${T4O_WORK_DIR}/t4o-test-report-${SETUP_LABEL}-${STAMP}.md"

scope_has()  { t4o_scope_includes "$1"; }
# A missing result means the step never got far enough to record one. Render it
# as NO RESULT rather than an empty cell — a blank reads like "nothing to
# report" when it actually means "not proven", and it is counted as a failure.
result_of()  { local r="${1^^}"; local v="${r}_RESULT"; echo "${!v:-NO RESULT}"; }

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
{
  echo "# T4O functional test report"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Setup | ${SETUP_LABEL} |"
  echo "| Distro | ${T4O_DISTRO} |"
  echo "| Backup target scope | **${T4O_BT_SCOPE}** |"
  echo "| Date (UTC) | $(date -u '+%Y-%m-%d %H:%M') |"
  echo "| Keystone | ${OS_AUTH_URL:-?} |"
  echo "| Test user | ${OS_USERNAME:-?} / project ${OS_PROJECT_NAME:-?} |"

  # Build identifiers, when the build step left them behind.
  BA="${TRILIO_ENV_DIR}/build_artifacts.yaml"
  if [[ -f "$BA" ]]; then
      echo "| Build artifacts | \`$BA\` |"
  else
      echo "| Build artifacts | build details unavailable |"
  fi
  echo

  echo "## Backup results"
  echo
  echo "| Target | Backup target type | Result |"
  echo "|---|---|---|"
  for role in s3 nfs; do
      if scope_has "$role"; then
          btt_var="BT_$(echo "$role" | tr a-z A-Z)_BTT_NAME"
          echo "| ${role^^} | ${!btt_var:-?} | $(result_of "$role") |"
      else
          # Never blank, never a pass — a single-target run must not read as
          # full coverage.
          echo "| ${role^^} | — | NOT TESTED (scope: ${T4O_BT_SCOPE}) |"
      fi
  done
  echo

  if [[ -f "$MATRIX_FILE" ]]; then
      echo "## Backup target reachability (step 1)"
      echo
      echo '```'
      cat "$MATRIX_FILE"
      echo '```'
      echo
  fi

  echo "## Resources created by this run"
  echo
  if [[ -s "$T4O_RESOURCES_FILE" ]]; then
      echo '```'
      cat "$T4O_RESOURCES_FILE"
      echo '```'
  else
      echo "_none recorded_"
  fi
  echo
} > "$REPORT"

t4o_info ""
t4o_info "=== Step 8: Report and cleanup ==="
t4o_info "Report written to: $REPORT"

# ---------------------------------------------------------------------------
# Decide
# ---------------------------------------------------------------------------
tested=0 passed=0 failed=0
for role in s3 nfs; do
    scope_has "$role" || continue
    tested=$((tested+1))
    case "$(result_of "$role")" in
      PASS) passed=$((passed+1)) ;;
      "")   failed=$((failed+1)) ;;   # no result recorded == not proven == failure
      *)    failed=$((failed+1)) ;;
    esac
done

t4o_info "Tested: $tested   passed: $passed   failed: $failed"

if [[ "$MODE" == "--report-only" ]]; then
    t4o_info "--report-only: leaving every resource in place."
    exit 0
fi

if [[ $failed -gt 0 && "$MODE" != "--force" ]]; then
    t4o_info ""
    t4o_error "At least one tested backup did not pass — DELETING NOTHING."
    t4o_error "The VMs, volumes, workloads and snapshots below are left for inspection:"
    [[ -s "$T4O_RESOURCES_FILE" ]] && sed 's/^/  /' "$T4O_RESOURCES_FILE"
    t4o_info ""
    t4o_info "Re-run with --force once you are done to clean them up."
    rm -f "$T4O_OPENRC"
    exit 1
fi

# ---------------------------------------------------------------------------
# Clean up — snapshots, then workloads, then VMs, then volumes
# ---------------------------------------------------------------------------
t4o_info ""
if [[ $failed -gt 0 ]]; then
    # --force is the only way to reach here with failures, and saying
    # "all passed" would misreport the run.
    t4o_info "--force: removing this run's resources despite $failed failed backup(s)."
else
    t4o_info "All tested backups passed — removing the resources this run created."
fi
t4o_info "(backup targets are shared infrastructure and are never deleted)"

for role in s3 nfs; do
    scope_has "$role" || continue
    R="$(echo "$role" | tr a-z A-Z)"

    snap_var="${R}_SNAPSHOT_ID";  snap="${!snap_var:-}"
    wl_var="${R}_WORKLOAD_ID";    wl="${!wl_var:-}"
    inst_var="${R}_INSTANCE_ID";  inst="${!inst_var:-}"
    vols_var="${R}_VOLUME_IDS";   vols="${!vols_var:-}"

    if [[ -n "$snap" ]]; then
        t4o_info "  snapshot $snap"
        wlm_exec snapshot-delete "$snap" >/dev/null 2>&1 || t4o_warn "    delete failed"
        sleep 5
    fi
    if [[ -n "$wl" ]]; then
        t4o_info "  workload $wl"
        wlm_exec workload-delete "$wl" >/dev/null 2>&1 || t4o_warn "    delete failed"
        sleep 5
    fi
    if [[ -n "$inst" ]]; then
        t4o_info "  server $inst"
        # Detach first so the volumes are deletable.
        for v in $vols; do os_exec server remove volume "$inst" "$v" >/dev/null 2>&1 || true; done
        os_exec server delete "$inst" >/dev/null 2>&1 || t4o_warn "    delete failed"
    fi
    for v in $vols; do
        t4o_info "  volume $v"
        for _ in 1 2 3 4 5 6; do
            os_exec volume delete "$v" >/dev/null 2>&1 && break
            sleep 10        # the server delete may still be releasing it
        done
    done
done

rm -f "$T4O_OPENRC"
t4o_info ""
t4o_info "Cleanup complete. Report: $REPORT"
exit 0
