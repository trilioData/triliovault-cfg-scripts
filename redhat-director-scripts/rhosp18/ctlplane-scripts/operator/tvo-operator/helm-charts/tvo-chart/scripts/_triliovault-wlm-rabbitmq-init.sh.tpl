#!/bin/bash
set -e
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"
RABBIT_TRANSIENT_QUORUM_QUEUE="{{- .Values.rabbitmq.common.rabbit_transient_quorum_queue -}}"

# RabbitMQ user to be created
WLMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.wlm_api.user -}}"
WLMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.wlm_api.vhost -}}"

# Export credentials for rabbitmqctl
export RABBITMQ_ADMIN_USER
export RABBITMQ_ADMIN_PASSWORD


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

# When rabbit_transient_quorum_queue is enabled, oslo.messaging declares fanout
# exchanges (e.g. workloadmgr-scheduler_fanout) with durable=true. If that
# exchange was created by an older client (pre-6.2.1) with durable=false,
# RabbitMQ rejects the new declare with PRECONDITION_FAILED and the pod
# crash-loops until the exchange is auto-deleted on its own (TVAULT-7519).
# Delete any stale non-durable fanout exchange in this vhost up front so the
# pods succeed immediately.
delete_stale_nondurable_fanout_exchanges() {
  vhost="$1"
  shift
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" -V "${vhost}" "$@" \
    list exchanges name type durable -f tsv |
  while IFS=$'\t' read -r name type durable; do
    case "$name" in
      *_fanout)
        if [ "$type" = "fanout" ] && [ "$durable" = "False" ]; then
          echo "Deleting stale non-durable fanout exchange '${name}' in vhost '${vhost}'"
          rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" -V "${vhost}" "$@" \
            delete exchange name="${name}"
        fi
        ;;
    esac
  done
}

if [ "{{- .Values.rabbitmq.common.ssl -}}" == "true" ]; then
  # SSL is enabled, include --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare user name="${WLMAPI_RABBITMQ_USER_NAME}" password="${WLMAPI_RABBITMQ_USER_PASSWORD}" tags="management"

  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare vhost name="${WLMAPI_RABBITMQ_VHOST_NAME}"

  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare permission vhost="${WLMAPI_RABBITMQ_VHOST_NAME}" user="${WLMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"

  if [ "$RABBIT_TRANSIENT_QUORUM_QUEUE" == "true" ]; then
    delete_stale_nondurable_fanout_exchanges "${WLMAPI_RABBITMQ_VHOST_NAME}" --ssl
  fi

else
  # SSL is not enabled, omit --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare user name="${WLMAPI_RABBITMQ_USER_NAME}" password="${WLMAPI_RABBITMQ_USER_PASSWORD}" tags="management"

  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare vhost name="${WLMAPI_RABBITMQ_VHOST_NAME}"

  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare permission vhost="${WLMAPI_RABBITMQ_VHOST_NAME}" user="${WLMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"

  if [ "$RABBIT_TRANSIENT_QUORUM_QUEUE" == "true" ]; then
    delete_stale_nondurable_fanout_exchanges "${WLMAPI_RABBITMQ_VHOST_NAME}"
  fi
fi
