#!/bin/bash
set -e
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"
RABBIT_TRANSIENT_QUORUM_QUEUE="{{- .Values.rabbitmq.common.rabbit_transient_quorum_queue -}}"
WLMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.wlm_api.vhost -}}"

export RABBITMQ_ADMIN_USER
export RABBITMQ_ADMIN_PASSWORD

if [ "$RABBIT_TRANSIENT_QUORUM_QUEUE" != "true" ]; then
  echo "SKIPPED: rabbit_transient_quorum_queue is '${RABBIT_TRANSIENT_QUORUM_QUEUE:-unset}' (not 'true') - stale fanout exchange cleanup does not apply."
  exit 0
fi

echo "rabbit_transient_quorum_queue is enabled - will scan vhost '${WLMAPI_RABBITMQ_VHOST_NAME}' for stale non-durable fanout exchanges."

URL="https://trilio-rabbitmq-cluster.trilio-openstack.svc:15671/api/vhosts"

while true; do
  if curl -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}" -k --silent --fail "$URL" > /dev/null; then
    echo "RabbitMQ API is now reachable!"
    break
  else
    echo "RabbitMQ API not reachable yet. Retrying in 5 seconds..."
    sleep 5
  fi
done

# This runs as a pre-upgrade hook, before this release's Deployments are touched, so the
# workloadmgr vhost here always already exists from whatever version was previously
# installed (there is nothing to clean on a fresh install, hence pre-upgrade only, not
# pre-install).
#
# When rabbit_transient_quorum_queue is enabled, oslo.messaging declares fanout exchanges
# (e.g. workloadmgr-scheduler_fanout, workloadmgr-cron_fanout, workloadmgr-workloads_fanout)
# with durable=true. If those exchanges were created by an older client with durable=false,
# RabbitMQ rejects the new declare with PRECONDITION_FAILED, and oslo.messaging's own retry
# fallback mis-declares the exchange too (wrong auto_delete), so the mismatch never resolves
# on its own - worse, concurrent pod replicas across wlm-scheduler/wlm-cron/wlm-workloads
# hitting this at once leak large numbers of orphaned per-consumer queues (TVAULT-7519).
# Deleting the stale exchange here, before any pod of the new release starts, means every
# pod's first declare attempt hits a vhost with either no exchange (fresh create,
# durable=true) or one already durable=true - no race, no PRECONDITION_FAILED.
#
# Scoped narrowly on purpose: only a *_fanout exchange that is both type=fanout and
# durable=False gets deleted - every other exchange (already durable=true, not a *_fanout
# name, or not type fanout) is left untouched, and this whole script is a no-op unless
# rabbit_transient_quorum_queue is enabled. Queues are intentionally NOT touched here, even
# though the same bug leaks orphaned per-consumer queues under concurrent pod startup -
# that cleanup is out of scope for this fix.
if [ "{{- .Values.rabbitmq.common.ssl -}}" == "true" ]; then
  RABBITMQADMIN_EXTRA_ARGS="--ssl"
else
  RABBITMQADMIN_EXTRA_ARGS=""
fi

# Process substitution rather than a pipe: a piped `while` runs in a subshell, so the
# counters below would be lost and the summary would always report zero.
examined=0
deleted=0
while IFS=$'\t' read -r name type durable; do
  case "$name" in
    *_fanout)
      examined=$((examined + 1))
      if [ "$type" = "fanout" ] && [ "$durable" = "False" ]; then
        echo "DELETING stale non-durable fanout exchange '${name}' (type=${type}, durable=${durable}) in vhost '${WLMAPI_RABBITMQ_VHOST_NAME}'"
        rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" -V "${WLMAPI_RABBITMQ_VHOST_NAME}" $RABBITMQADMIN_EXTRA_ARGS \
          delete exchange name="${name}"
        deleted=$((deleted + 1))
      else
        echo "KEEPING fanout exchange '${name}' (type=${type}, durable=${durable}) - already correct, nothing to fix"
      fi
      ;;
  esac
done < <(rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" -V "${WLMAPI_RABBITMQ_VHOST_NAME}" $RABBITMQADMIN_EXTRA_ARGS \
  list exchanges name type durable -f tsv)

echo "SUMMARY: vhost '${WLMAPI_RABBITMQ_VHOST_NAME}' - ${examined} '*_fanout' exchange(s) examined, ${deleted} deleted."
