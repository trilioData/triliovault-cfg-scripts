#!/bin/bash
set -e
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"
RABBIT_TRANSIENT_QUORUM_QUEUE="{{- .Values.rabbitmq.common.rabbit_transient_quorum_queue -}}"
DMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.datamover_api.vhost -}}"

export RABBITMQ_ADMIN_USER
export RABBITMQ_ADMIN_PASSWORD

if [ "$RABBIT_TRANSIENT_QUORUM_QUEUE" != "true" ]; then
  echo "SKIPPED: rabbit_transient_quorum_queue is '${RABBIT_TRANSIENT_QUORUM_QUEUE:-unset}' (not 'true') - stale fanout exchange cleanup does not apply."
  exit 0
fi

# rabbitmqadmin's tsv output capitalises booleans, so compare against 'True'/'False',
# not 'true'/'false'. The early exit above means the wanted value is always durable=true.
DESIRED_DURABLE="True"

# Exchanges in this vhost that are NOT owned by a control plane service and must be left
# alone. contego_fanout is declared by the datamover running on each compute node: that is
# a data plane service, it is not restarted by a control plane upgrade, and by the
# documented upgrade order it is still on the previous release (where
# rabbit_transient_quorum_queue is unset, so it declares durable=false) until the data
# plane is upgraded afterwards. Forcing this exchange to durable=true would therefore break
# the still-running old datamover on every compute node instead of fixing anything here -
# dmapi reaches datamover over the 'contego' topic exchange, not over its fanout. It
# converges on its own once the data plane is upgraded. TVAULT-7572.
SKIP_EXCHANGES="contego_fanout"

# Bounded, so this job can never be the thing that stalls an upgrade. It runs at
# hook weight 99, i.e. after job-wait-for-rabbitmq-cluster has already confirmed the
# broker Ready, so 5 minutes is generous.
MAX_API_WAIT_ATTEMPTS=60
API_WAIT_INTERVAL=5

# How many times to re-list and re-fix before giving up. A vhost that had stale
# exchanges needs two passes: one to converge them, one to verify nothing raced us.
MAX_PASSES=5
PASS_INTERVAL=5

echo "rabbit_transient_quorum_queue is enabled - will converge '*_fanout' exchanges in vhost '${DMAPI_RABBITMQ_VHOST_NAME}' to durable=true."

URL="https://trilio-rabbitmq-cluster.trilio-openstack.svc:15671/api/vhosts"

api_ready=0
attempt=1
while [ "$attempt" -le "$MAX_API_WAIT_ATTEMPTS" ]; do
  if curl -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}" -k --silent --fail "$URL" > /dev/null; then
    echo "RabbitMQ API is now reachable!"
    api_ready=1
    break
  fi
  echo "RabbitMQ API not reachable yet (attempt ${attempt}/${MAX_API_WAIT_ATTEMPTS}). Retrying in ${API_WAIT_INTERVAL} seconds..."
  sleep "$API_WAIT_INTERVAL"
  attempt=$((attempt + 1))
done

if [ "$api_ready" -ne 1 ]; then
  echo "WARNING: RabbitMQ management API never became reachable - skipping fanout exchange convergence."
  echo "WARNING: the upgrade continues; dmapi pods may crash-loop until RabbitMQ auto-deletes the stale exchange (pre-TVAULT-7572 behaviour)."
  exit 0
fi

# This runs as a post-upgrade hook at weight 99, i.e. immediately before this release's
# Deployments (they are themselves post-upgrade hooks at weight 100-104). So the dmapi vhost
# here always already exists from whatever version was previously installed - there is
# nothing to clean on a fresh install, hence upgrade-only.
#
# When rabbit_transient_quorum_queue is enabled, oslo.messaging declares fanout exchanges
# (e.g. dmapi_fanout) with durable=true. If that exchange was created by an older client
# with durable=false, RabbitMQ rejects the new declare with PRECONDITION_FAILED, and
# oslo.messaging's own retry fallback mis-declares the exchange too (wrong auto_delete),
# so the mismatch never resolves on its own - worse, concurrent pod replicas hitting this
# at once leak large numbers of orphaned per-consumer queues (TVAULT-7519).
#
# CONVERGE, DO NOT JUST DELETE (TVAULT-7572). Deleting the stale exchange on its own is a
# race we lose: every old-release pod is still running at this point (they are only replaced
# at hook weights 100-104), kombu's Producer re-declares its exchange on every publish, and
# oslo.messaging builds a fresh Producer per cast - so the next cast from any surviving old
# pod re-creates the exchange with durable=false and the new pods crash-loop exactly as
# before. Re-declaring it durable=true straight after the delete closes that window: from
# then on an old client's durable=false declare is the one that gets rejected, which for a
# publisher is a logged-and-retried error rather than a fatal one.
#
# Scoped narrowly on purpose: only a *_fanout exchange that is type=fanout, not in
# SKIP_EXCHANGES, and whose durable flag disagrees with rabbit_transient_quorum_queue is
# touched - every other exchange (already durable=true, not a *_fanout name, or not type
# fanout) is left untouched, and this whole script is a no-op unless
# rabbit_transient_quorum_queue is enabled. auto_delete is preserved as observed rather than
# forced, because forcing a value oslo.messaging does not declare would just move the
# PRECONDITION_FAILED onto auto_delete instead. Queues are intentionally NOT touched here,
# even though the same bug leaks orphaned per-consumer queues under concurrent pod startup -
# that cleanup is out of scope for this fix.
if [ "{{- .Values.rabbitmq.common.ssl -}}" == "true" ]; then
  RABBITMQADMIN_EXTRA_ARGS="--ssl"
else
  RABBITMQADMIN_EXTRA_ARGS=""
fi

rmqadmin() {
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" \
    -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    -V "${DMAPI_RABBITMQ_VHOST_NAME}" $RABBITMQADMIN_EXTRA_ARGS "$@"
}

converged=0
converged_pass=0
for pass in $(seq 1 "$MAX_PASSES"); do
  # Capture the listing first so a failed list is detectable, then feed the loop with a
  # here-string. A pipe would run the `while` in a subshell and lose the counters below.
  if ! exchanges="$(rmqadmin list exchanges name type durable auto_delete -f tsv)"; then
    echo "WARNING: could not list exchanges in vhost '${DMAPI_RABBITMQ_VHOST_NAME}' (pass ${pass}/${MAX_PASSES})."
    sleep "$PASS_INTERVAL"
    continue
  fi

  examined=0
  mismatched=0
  fixed=0
  failed=0
  while IFS=$'\t' read -r name type durable auto_delete; do
    # rabbitmqadmin -f tsv emits a header row
    if [ "$name" = "name" ]; then
      continue
    fi
    case "$name" in
      *_fanout) ;;
      *) continue ;;
    esac
    if [ "$type" != "fanout" ]; then
      continue
    fi
    case " $SKIP_EXCHANGES " in
      *" $name "*)
        if [ "$pass" -eq 1 ]; then
          echo "SKIPPING fanout exchange '${name}' (type=${type}, durable=${durable}, auto_delete=${auto_delete}) - owned by the data plane datamover, not by a control plane service"
        fi
        continue
        ;;
    esac

    examined=$((examined + 1))
    if [ "$durable" = "$DESIRED_DURABLE" ]; then
      if [ "$pass" -eq 1 ]; then
        echo "KEEPING fanout exchange '${name}' (type=${type}, durable=${durable}, auto_delete=${auto_delete}) - already correct, nothing to fix"
      fi
      continue
    fi

    mismatched=$((mismatched + 1))
    if [ "$auto_delete" = "True" ]; then
      observed_auto_delete="true"
    else
      observed_auto_delete="false"
    fi

    echo "DELETING stale non-durable fanout exchange '${name}' (type=${type}, durable=${durable}, auto_delete=${auto_delete}) in vhost '${DMAPI_RABBITMQ_VHOST_NAME}'"
    if rmqadmin delete exchange name="${name}" \
       && rmqadmin declare exchange name="${name}" type=fanout durable=true auto_delete="${observed_auto_delete}"; then
      echo "RE-DECLARED '${name}' as type=fanout durable=true auto_delete=${observed_auto_delete}"
      fixed=$((fixed + 1))
    else
      echo "WARNING: could not converge fanout exchange '${name}' - will retry on the next pass"
      failed=$((failed + 1))
    fi
  done <<< "$exchanges"

  echo "PASS ${pass}/${MAX_PASSES}: vhost '${DMAPI_RABBITMQ_VHOST_NAME}' - ${examined} '*_fanout' exchange(s) examined, ${mismatched} mismatched, ${fixed} converged, ${failed} failed."

  if [ "$mismatched" -eq 0 ]; then
    converged=1
    converged_pass="$pass"
    break
  fi
  sleep "$PASS_INTERVAL"
done

if [ "$converged" -eq 1 ]; then
  echo "SUMMARY: vhost '${DMAPI_RABBITMQ_VHOST_NAME}' - CONVERGED after ${converged_pass} pass(es); every '*_fanout' exchange is now durable=true."
else
  echo "WARNING: vhost '${DMAPI_RABBITMQ_VHOST_NAME}' - NOT CONVERGED after ${MAX_PASSES} passes; a non-durable '*_fanout' exchange is still being re-created by an old client."
  echo "WARNING: exiting 0 so the upgrade is not blocked - dmapi pods may crash-loop until RabbitMQ auto-deletes the stale exchange (pre-TVAULT-7572 behaviour)."
fi
exit 0
