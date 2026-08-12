#!/usr/bin/env bash
#
# Audits and cleans up orphaned classic RabbitMQ queues on the Trilio
# RabbitMQ cluster (dmapi/workloadmgr vhosts) on RHOSO18, ahead of/after
# enabling quorum queues. Runs entirely via `rabbitmqadmin` from inside a
# triliovault-wlm-api pod (it's already baked into that image, and the pod
# already trusts the cluster's TLS cert via combined-ca-bundle, so plain
# --ssl is enough — same as the product's own rabbitmq-init job scripts,
# see helm-charts/tvo-chart/scripts/_triliovault-wlm-rabbitmq-init.sh.tpl).
#
# rabbitmqctl is deliberately NOT used: it authenticates over the Erlang
# distribution port using the shared ~/.erlang.cookie, which only exists on
# the rabbitmq statefulset's own pods. rabbitmqadmin's management-API
# equivalent (list/delete queues+exchanges) covers everything we need here.
#
# Scope: this script deletes every queue AND exchange that is durable=false,
# regardless of current consumers/bindings. It never touches anything
# already durable/quorum.
#
# WARNING: deleting a classic queue/exchange that is currently in use (a
# live wlm-api/wlm-workloads/wlm-cron/wlm-scheduler/dmapi/dms connection
# consuming from it or publishing to it) will break that in-flight RPC call
# or notification. Stop/quiesce the Trilio services first if you want a
# clean cutover.
#
# Usage:
#   ./cleanup_rabbit_vhosts.sh audit
#   ./cleanup_rabbit_vhosts.sh cleanup --dry-run
#   ./cleanup_rabbit_vhosts.sh cleanup --apply
#   ./cleanup_rabbit_vhosts.sh cleanup --apply --force
#   ./cleanup_rabbit_vhosts.sh delete-vhosts --dry-run
#   ./cleanup_rabbit_vhosts.sh delete-vhosts --apply
#
# `cleanup`/`delete-vhosts` with no mode is a hard error — you must say
# which you mean.
#
# --force (cleanup only): an exclusive queue (reply_*/*_fanout_<uuid>/
# dms_reply_*) can only be deleted by the connection that declared it; a
# plain delete from rabbitmqadmin gets rejected with "cannot obtain
# exclusive access". With --force, on that rejection the script looks up
# the queue's owning connection via the management API and force-closes
# it — RabbitMQ auto-deletes an exclusive queue the instant its owning
# connection closes. The owning client (wlm-api/wlm-workloads/wlm-cron/
# wlm-scheduler/dmapi/dms) will see a dropped connection and reconnect on
# its own.
#
# delete-vhosts: a heavier alternative to `cleanup` — deletes the entire
# dmapi/workloadmgr vhost (queues, exchanges, bindings, messages, and the
# service users' permission grants on that vhost) in one atomic operation,
# bypassing the exclusive-queue lock problem entirely. Only worth it if
# you're about to redeploy anyway with rabbit_quorum_queue enabled, since
# the vhost/user/permissions only get recreated by the ctlplane redeploy's
# rabbitmq-init job hooks (job-wlm-rabbitmq-init.yaml /
# job-datamover-api-rabbitmq-init.yaml) — nothing can reconnect until then.
#
# Defaults below come from the RHOSO18 helm chart
# (ctlplane-scripts/operator/tvo-operator/helm-charts/tvo-chart) and the
# RabbitMQ Cluster Operator's naming convention. Override via env vars if
# the customer's cluster differs, e.g.:
#   oc get secrets -n trilio-openstack | grep rabbitmq

set -euo pipefail

NAMESPACE="${NAMESPACE:-trilio-openstack}"
WLM_API_LABEL_SELECTOR="${WLM_API_LABEL_SELECTOR:-application=triliovault,component=wlm-api}"
WLM_API_CONTAINER="${WLM_API_CONTAINER:-triliovault-wlm-api}"
RABBITMQ_ADMIN_SECRET="${RABBITMQ_ADMIN_SECRET:-trilio-rabbitmq-cluster-default-user}"
RABBITMQ_HOST="${RABBITMQ_HOST:-trilio-rabbitmq-cluster.trilio-openstack.svc}"
RABBITMQ_PORT="${RABBITMQ_PORT:-15671}"
RABBITMQADMIN_BIN="${RABBITMQADMIN_BIN:-rabbitmqadmin}"
VHOSTS=(dmapi workloadmgr)

OC="${OC_BIN:-oc}"
command -v "$OC" >/dev/null 2>&1 || OC=kubectl

RABBITMQ_USER=""
RABBITMQ_PASS=""
WLM_API_POD=""

usage() {
  cat >&2 <<'EOF'
Usage:
  cleanup_rabbit_vhosts.sh audit
  cleanup_rabbit_vhosts.sh cleanup --dry-run
  cleanup_rabbit_vhosts.sh cleanup --apply
  cleanup_rabbit_vhosts.sh cleanup --apply --force
  cleanup_rabbit_vhosts.sh delete-vhosts --dry-run
  cleanup_rabbit_vhosts.sh delete-vhosts --apply
EOF
}

find_wlm_api_pod() {
  local pod
  pod=$("$OC" -n "$NAMESPACE" get pod -l "$WLM_API_LABEL_SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}')
  if [ -z "$pod" ]; then
    echo "No running wlm-api pod found in namespace ${NAMESPACE} (selector: ${WLM_API_LABEL_SELECTOR})" >&2
    exit 1
  fi
  echo "$pod"
}

exec_pod() {
  "$OC" -n "$NAMESPACE" exec "$WLM_API_POD" -c "$WLM_API_CONTAINER" -- bash -c "$1"
}

fetch_admin_credentials() {
  echo "==> Fetching RabbitMQ admin credentials from secret/${RABBITMQ_ADMIN_SECRET}"
  RABBITMQ_USER=$("$OC" -n "$NAMESPACE" get secret "$RABBITMQ_ADMIN_SECRET" -o jsonpath='{.data.username}' | base64 -d)
  RABBITMQ_PASS=$("$OC" -n "$NAMESPACE" get secret "$RABBITMQ_ADMIN_SECRET" -o jsonpath='{.data.password}' | base64 -d)
}

# Same flag style as helm-charts/tvo-chart/scripts/_triliovault-wlm-rabbitmq-init.sh.tpl
# and _triliovault-datamover-api-rabbitmq-init.sh.tpl: -H/-P/-u/-p/--ssl, no extra
# cert flags needed since the pod's system trust store already has the CA
# (combined-ca-bundle is mounted at /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem).
rmqadmin() {
  local vhost="$1"; shift
  exec_pod "${RABBITMQADMIN_BIN} -H '${RABBITMQ_HOST}' -P '${RABBITMQ_PORT}' -u '${RABBITMQ_USER}' -p '${RABBITMQ_PASS}' --ssl --vhost='${vhost}' $*"
}

setup() {
  WLM_API_POD=$(find_wlm_api_pod)
  echo "==> Using wlm-api pod: ${WLM_API_POD}"
  exec_pod "command -v '${RABBITMQADMIN_BIN}' >/dev/null 2>&1" \
    || { echo "rabbitmqadmin not found on PATH in ${WLM_API_POD} (expected at /usr/local/bin/rabbitmqadmin)" >&2; exit 1; }
  fetch_admin_credentials
  echo "==> Verifying rabbitmqadmin connectivity"
  exec_pod "${RABBITMQADMIN_BIN} -H '${RABBITMQ_HOST}' -P '${RABBITMQ_PORT}' -u '${RABBITMQ_USER}' -p '${RABBITMQ_PASS}' --ssl list vhosts" >/dev/null
}

audit_vhost() {
  local vhost="$1"
  echo "---- vhost: ${vhost} ----"
  echo "* queues:"
  rmqadmin "$vhost" "list queues name durable type consumers messages"
  echo "* exchanges:"
  rmqadmin "$vhost" "list exchanges name type durable"
}

classic_queues() {
  # Names of queues in $1 that are durable=false.
  local vhost="$1"
  rmqadmin "$vhost" "list queues name durable -f raw_json" | python3 -c '
import json, sys
for q in json.load(sys.stdin):
    if q.get("durable") is False:
        print(q["name"])
'
}

classic_exchanges() {
  # Names of exchanges in $1 that are durable=false (built-ins like amq.*
  # and the default "" exchange are always durable=true, so they never
  # show up here).
  local vhost="$1"
  rmqadmin "$vhost" "list exchanges name durable -f raw_json" | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    if e.get("durable") is False and e.get("name"):
        print(e["name"])
'
}

queue_exists() {
  local vhost="$1" queue="$2"
  rmqadmin "$vhost" "list queues name -f raw_json" | QNAME="$queue" python3 -c '
import json, os, sys
qname = os.environ["QNAME"]
data = json.load(sys.stdin)
sys.exit(0 if any(q.get("name") == qname for q in data) else 1)
'
}

owning_connection() {
  # Prints the connection_name that owns queue $2 in vhost $1 (empty if none/unknown).
  local vhost="$1" queue="$2"
  rmqadmin "$vhost" "list queues name consumer_details -f raw_json" | QNAME="$queue" python3 -c '
import json, os, sys
qname = os.environ["QNAME"]
for q in json.load(sys.stdin):
    if q.get("name") == qname:
        for c in (q.get("consumer_details") or []):
            name = c.get("channel_details", {}).get("connection_name")
            if name:
                print(name)
        break
'
}

unlock_and_delete_queue() {
  local vhost="$1" queue="$2" conn
  conn=$(owning_connection "$vhost" "$queue")
  if [ -z "$conn" ]; then
    echo "  Could not identify the owning connection for '${queue}'" >&2
    return 1
  fi
  echo "  Closing connection '${conn}' (owner of '${queue}')"
  exec_pod "${RABBITMQADMIN_BIN} -H '${RABBITMQ_HOST}' -P '${RABBITMQ_PORT}' -u '${RABBITMQ_USER}' -p '${RABBITMQ_PASS}' --ssl close connection name='${conn}'" || true
  rmqadmin "$vhost" "delete queue name='${queue}'" >/dev/null 2>&1 || true
  ! queue_exists "$vhost" "$queue"
}

delete_vhost() {
  local vhost="$1"
  exec_pod "${RABBITMQADMIN_BIN} -H '${RABBITMQ_HOST}' -P '${RABBITMQ_PORT}' -u '${RABBITMQ_USER}' -p '${RABBITMQ_PASS}' --ssl delete vhost name='${vhost}'"
}

cmd_audit() {
  setup
  for v in "${VHOSTS[@]}"; do audit_vhost "$v"; done
}

cmd_delete_vhosts() {
  local mode="${1:-}"
  if [ "$mode" != "--dry-run" ] && [ "$mode" != "--apply" ]; then
    echo "error: 'delete-vhosts' requires an explicit mode" >&2
    usage
    exit 1
  fi

  setup

  cat <<'EOF'
WARNING: this deletes the ENTIRE vhost — every queue, exchange, binding, and
any messages still sitting in those queues, unconditionally (this includes
exclusive/locked queues that 'cleanup' cannot touch). It also drops the
service users' permission grants on that vhost (the users themselves
survive). Nothing can reconnect until the vhost is recreated, which happens
automatically on the next ctlplane redeploy via the rabbitmq-init job hooks.

EOF

  for v in "${VHOSTS[@]}"; do
    echo "---- vhost: ${v} ----"
    echo "* currently holds:"
    rmqadmin "$v" "list queues name messages consumers" || echo "  (vhost may already be gone)"
    rmqadmin "$v" "list exchanges name type" || true

    if [ "$mode" == "--dry-run" ]; then
      echo "(dry-run: would delete vhost '${v}' and everything above)"
      continue
    fi

    echo "Deleting vhost '${v}'"
    delete_vhost "$v"
  done

  if [ "$mode" == "--apply" ]; then
    cat <<EOF

==> Done. ${VHOSTS[*]} no longer exist.
Next: set rabbit_quorum_queue=true (and the dmapi/dms equivalent) in the
ctlplane inputs and re-run deploy_tvo_control_plane.sh — that recreates the
vhosts/users/permissions and rolls the pods onto the new config.
EOF
  fi
}

cmd_cleanup() {
  local mode="" force="false"
  for a in "$@"; do
    case "$a" in
      --dry-run|--apply) mode="$a" ;;
      --force) force="true" ;;
      *) echo "error: unknown option '$a'" >&2; usage; exit 1 ;;
    esac
  done
  if [ -z "$mode" ]; then
    echo "error: 'cleanup' requires an explicit mode" >&2
    usage
    exit 1
  fi
  if [ "$force" == "true" ] && [ "$mode" != "--apply" ]; then
    echo "error: --force only applies to --apply" >&2
    usage
    exit 1
  fi

  setup

  local failed=()

  for v in "${VHOSTS[@]}"; do
    echo "---- vhost: ${v} ----"

    mapfile -t queue_targets < <(classic_queues "$v")
    if [ "${#queue_targets[@]}" -eq 0 ]; then
      echo "No classic (durable=false) queues found."
    else
      echo "Classic (durable=false) queues:"
      printf '  %s\n' "${queue_targets[@]}"
      if [ "$mode" == "--apply" ]; then
        for q in "${queue_targets[@]}"; do
          echo "Deleting queue '${q}' in vhost '${v}'"
          if ! rmqadmin "$v" "delete queue name='${q}'"; then
            if [ "$force" == "true" ] && unlock_and_delete_queue "$v" "$q"; then
              echo "  Deleted '${q}' after closing its owning connection"
            elif [ "$force" == "true" ]; then
              echo "  WARNING: could not delete queue '${q}' even after --force — skipping" >&2
              failed+=("queue ${v}/${q}")
            else
              echo "  WARNING: could not delete queue '${q}' — still in use, skipping (use --force to close its owning connection)" >&2
              failed+=("queue ${v}/${q}")
            fi
          fi
        done
      fi
    fi

    mapfile -t exchange_targets < <(classic_exchanges "$v")
    if [ "${#exchange_targets[@]}" -eq 0 ]; then
      echo "No classic (durable=false) exchanges found."
    else
      echo "Classic (durable=false) exchanges:"
      printf '  %s\n' "${exchange_targets[@]}"
      if [ "$mode" == "--apply" ]; then
        for e in "${exchange_targets[@]}"; do
          echo "Deleting exchange '${e}' in vhost '${v}'"
          if ! rmqadmin "$v" "delete exchange name='${e}'"; then
            echo "  WARNING: could not delete exchange '${e}' — still in use, skipping" >&2
            failed+=("exchange ${v}/${e}")
          fi
        done
      fi
    fi

    if [ "$mode" == "--dry-run" ] && { [ "${#queue_targets[@]}" -gt 0 ] || [ "${#exchange_targets[@]}" -gt 0 ]; }; then
      echo "(dry-run: re-run with 'cleanup --apply' to actually delete these)"
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "==> ${#failed[@]} resource(s) could not be deleted (owned by an active connection — e.g. exclusive reply/fanout queues):"
    printf '  %s\n' "${failed[@]}"
    echo "They'll go away once the owning pod (wlm-api/wlm-workloads/wlm-cron/wlm-scheduler/dmapi/dms) reconnects or restarts. Re-run cleanup afterwards to catch them."
  fi
}

case "${1:-}" in
  audit)         cmd_audit ;;
  cleanup)       shift; cmd_cleanup "$@" ;;
  delete-vhosts) cmd_delete_vhosts "${2:-}" ;;
  *) usage; exit 1 ;;
esac
