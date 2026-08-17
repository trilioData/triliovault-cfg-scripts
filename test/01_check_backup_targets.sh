#!/usr/bin/env bash
# 01_check_backup_targets.sh — backup target reachability gate.
#
# THE FIRST REAL CHECK, AND A HARD GATE. This runs before the licence, before
# the trust, before anything is created or modified on the cloud. An unreachable
# backup target makes the rest of the run pointless, and every later step would
# leave state behind on a cloud that was never going to produce a backup.
# Failing here means a failed run changed nothing.
#
# Both WLM *and* every DataMover node are probed. WLM writes JSON metadata, the
# DataMover writes qcow2 data, and they sit on different hosts — a target only
# WLM can reach produces a workload that creates fine and then fails mid-
# snapshot. That is exactly the failure this gate exists to prevent.
#
# Usage:
#   bash 01_check_backup_targets.sh              # probe once, report, exit
#   bash 01_check_backup_targets.sh --wait       # re-probe on ENTER until it passes
#
# Environment:
#   T4O_BT_SCOPE    s3 | nfs | both        (default both)
#   T4O_S3_TARGET   name of the s3 entry to use instead of the default-flagged
#   T4O_NFS_TARGET  name of the nfs entry to use instead of the first
#
# Exit codes:
#   0  every selected target is reachable from every node
#   2  at least one probe failed — caller decides what to do next
#   1  setup error (missing definitions, bad scope, no distro)
#
# On exit 2 the caller (the t4o-test skill, or a human) chooses: fix the
# problem and re-check, pick a different target via T4O_S3_TARGET/T4O_NFS_TARGET,
# narrow T4O_BT_SCOPE to drop the failing type, or abort. Nothing has changed,
# so any of those is safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./t4o_env.sh
source "$SCRIPT_DIR/t4o_env.sh"

WAIT_MODE=0
[[ "${1:-}" == "--wait" ]] && WAIT_MODE=1

t4o_init
t4o_load_backup_targets

MATRIX_FILE="${T4O_WORK_DIR}/reachability_matrix.txt"

# ---------------------------------------------------------------------------
# Probes
#
# Each returns 0 on success and prints a one-line reason on failure. The three
# failure kinds are kept distinct on purpose — an unresolvable hostname, a
# firewalled port and an untrusted CA have different fixes, and collapsing them
# into "unreachable" throws away the only useful part of the message.
# ---------------------------------------------------------------------------

# run_on <node-label> <command...> — dispatch to WLM or a DataMover node
run_on() {
    local node="$1"; shift
    if [[ "$node" == "WLM" ]]; then
        wlm_shell "$*" 2>&1
    else
        dm_shell "$node" "$*" 2>&1
    fi
}

probe_dns() {
    local node="$1" host="$2" out
    if t4o_is_ip "$host"; then
        echo "SKIP(ip)"; return 0
    fi
    out=$(run_on "$node" "getent hosts '$host' 2>/dev/null | head -1")
    if [[ -n "$out" ]]; then
        echo "PASS"; return 0
    fi
    echo "FAIL: cannot resolve '$host'"; return 1
}

# _curl_probe <node> <url> <extra-curl-args> — returns "<rc>|<http_code>|<text>"
#
# curl's own exit status decides pass/fail, NOT the digits in its output.
# Scraping digits out of a merged stdout+stderr stream reads the "60" in
# "curl: (60) SSL certificate problem" as part of the HTTP code and turns a
# hard failure into a false PASS. Tag both values and parse them explicitly.
_curl_probe() {
    local node="$1" url="$2" extra="${3:-}"
    run_on "$node" "curl -sS $extra -o /dev/null -w 'CODE:%{http_code}' --max-time 15 '$url' 2>&1; printf '|RC:%s' \$?"
}

_curl_parse() {                       # <raw>  ->  sets _RC and _CODE
    local raw="$1"
    _RC=$(printf '%s' "$raw"   | sed -n 's/.*|RC:\([0-9]\+\).*/\1/p'  | tail -1)
    _CODE=$(printf '%s' "$raw" | sed -n 's/.*CODE:\([0-9]\+\).*/\1/p' | tail -1)
    _TEXT=$(printf '%s' "$raw" | sed 's/CODE:[0-9]*//; s/|RC:[0-9]*//' | tr '\n' ' ' | cut -c1-120)
    [[ -z "$_RC" ]] && _RC=1
}

probe_s3() {
    local node="$1" url="$2" raw
    # Any HTTP response — including 403 — proves the endpoint is reachable.
    # Only a connect/DNS/timeout error (curl rc != 0) means it is not.
    # -k here on purpose: this row answers "can I reach it", not "do I trust it".
    raw=$(_curl_probe "$node" "$url" "-k")
    _curl_parse "$raw"
    if [[ "$_RC" == "0" ]]; then
        echo "PASS(http ${_CODE:-?})"; return 0
    fi
    echo "FAIL: unreachable (curl rc=$_RC) — $_TEXT"; return 1
}

probe_s3_tls() {
    local node="$1" url="$2" raw
    # Repeat WITHOUT -k. Failing here while probe_s3 passed means the endpoint
    # is reachable but its certificate is not trusted on this node — a distinct
    # problem with a distinct fix (install the CA), so it gets its own row.
    raw=$(_curl_probe "$node" "$url" "")
    _curl_parse "$raw"
    if [[ "$_RC" == "0" ]]; then
        echo "PASS(http ${_CODE:-?})"; return 0
    fi
    echo "FAIL: TLS not trusted (curl rc=$_RC) — $_TEXT"; return 1
}

probe_nfs() {
    local node="$1" server="$2" out
    out=$(run_on "$node" "showmount -e '$server' 2>&1 | head -5")
    if printf '%s' "$out" | grep -qiE 'export list|/'; then
        echo "PASS"; return 0
    fi
    # showmount may be blocked while NFS itself works; fall back to a port probe.
    out=$(run_on "$node" "timeout 10 bash -c '</dev/tcp/$server/2049' 2>&1 && echo TCPOK")
    if printf '%s' "$out" | grep -q TCPOK; then
        echo "PASS(tcp/2049)"; return 0
    fi
    echo "FAIL: no NFS response — $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"; return 1
}

# ---------------------------------------------------------------------------
# One full pass over every selected target and every node
# ---------------------------------------------------------------------------
run_checks() {
    local failures=0
    : > "$MATRIX_FILE"

    local nodes=("WLM")
    local h
    while read -r h; do [[ -n "$h" ]] && nodes+=("$h"); done < <(dm_hosts)

    if [[ ${#nodes[@]} -le 1 ]]; then
        t4o_warn "No DataMover nodes found. The DataMover is what actually moves backup data —"
        t4o_warn "if this cloud has compute nodes, its reachability is going UNVERIFIED."
    fi

    printf '%-22s %-26s %-10s %s\n' "TARGET" "NODE" "CHECK" "RESULT" | tee -a "$MATRIX_FILE"
    printf '%s\n' "--------------------------------------------------------------------------------" | tee -a "$MATRIX_FILE"

    local row
    for kind in s3 nfs; do
        t4o_scope_includes "$kind" || continue

        local label host
        if [[ "$kind" == "s3" ]]; then
            label="$BT_S3_NAME (s3)"; host="$(t4o_target_host s3)"
        else
            label="$BT_NFS_NAME (nfs)"; host="$(t4o_target_host nfs)"
        fi

        for node in "${nodes[@]}"; do
            row=$(probe_dns "$node" "$host") || failures=$((failures+1))
            printf '%-22s %-26s %-10s %s\n' "$label" "$node" "dns" "$row" | tee -a "$MATRIX_FILE"

            if [[ "$kind" == "s3" ]]; then
                row=$(probe_s3 "$node" "$BT_S3_ENDPOINT") || failures=$((failures+1))
                printf '%-22s %-26s %-10s %s\n' "$label" "$node" "reach" "$row" | tee -a "$MATRIX_FILE"

                if [[ "$BT_S3_SSL" == "true" ]]; then
                    row=$(probe_s3_tls "$node" "$BT_S3_ENDPOINT")
                    local tls_rc=$?
                    printf '%-22s %-26s %-10s %s\n' "$label" "$node" "tls" "$row" | tee -a "$MATRIX_FILE"
                    # A CA cert supplied in backup_targets.yaml is passed to the
                    # backup target at creation, so an untrusted system store is
                    # a warning here, not a gate failure.
                    if [[ $tls_rc -ne 0 ]]; then
                        if [[ -n "${BT_S3_CA_CERT_FILE:-}" ]]; then
                            t4o_warn "$label: system CA store on $node does not trust the endpoint, but a CA cert is supplied in backup_targets.yaml and will be passed to the backup target. Continuing."
                        else
                            failures=$((failures+1))
                        fi
                    fi
                fi
            else
                row=$(probe_nfs "$node" "$host") || failures=$((failures+1))
                printf '%-22s %-26s %-10s %s\n' "$label" "$node" "nfs" "$row" | tee -a "$MATRIX_FILE"
            fi
        done
    done

    return $failures
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
t4o_info ""
t4o_info "=== Step 1: Backup target reachability (scope: $T4O_BT_SCOPE) ==="
t4o_info "Nothing is created or modified in this step."
t4o_info ""

while true; do
    run_checks
    rc=$?

    if [[ $rc -eq 0 ]]; then
        t4o_info ""
        t4o_info "All selected backup targets are reachable from WLM and every DataMover node."
        t4o_info "Matrix saved to: $MATRIX_FILE"
        exit 0
    fi

    t4o_info ""
    t4o_error "$rc reachability check(s) failed. Stopping before anything is created."
    t4o_info ""
    t4o_info "Nothing has been changed on this cloud. Your options:"
    t4o_info "  1. Fix the network/DNS/firewall/CA problem, then re-check."
    t4o_info "  2. Use a different backup target:"
    if t4o_scope_includes s3; then
        t4o_info "       S3 entries available:  $(t4o_list_targets s3 | tr '\n' ' ')"
        t4o_info "       re-run with: T4O_S3_TARGET=<name> bash $0"
    fi
    if t4o_scope_includes nfs; then
        t4o_info "       NFS entries available: $(t4o_list_targets nfs | tr '\n' ' ')"
        t4o_info "       re-run with: T4O_NFS_TARGET=<name> bash $0"
    fi
    t4o_info "  3. Narrow the scope to drop the failing type:"
    t4o_info "       re-run with: T4O_BT_SCOPE=s3   bash $0   (or nfs)"
    t4o_info "  4. Abort."
    t4o_info ""

    if [[ $WAIT_MODE -eq 1 && -t 0 ]]; then
        read -r -p "Press ENTER to re-check, or Ctrl-C to abort: " _
        t4o_info ""
        continue
    fi

    exit 2
done
