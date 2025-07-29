#!/bin/bash
set -e
RABBITMQ_ADMIN_USER="{{- .Values.rabbitmq.common.admin_user -}}"
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"

# RabbitMQ user to be created
WLMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.wlm_api.user -}}"
WLMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.wlm_api.vhost -}}"

# Export credentials for rabbitmqctl
export RABBITMQ_ADMIN_USER
export RABBITMQ_ADMIN_PASSWORD


URL="https://trilio-rabbitmq-cluster.trilio-openstack.svc:15671/api/vhosts"

# Loop until the curl command succeeds (exit code 0)
until curl -u "${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}" -k --silent --fail "$URL" > /dev/null; do
  echo "Waiting for RabbitMQ API to become available..."
  sleep 5
done


if [ "{{- .Values.rabbitmq.common.ssl -}}" == "true" ]; then
  # SSL is enabled, include --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare user name="${WLMAPI_RABBITMQ_USER_NAME}" password="${WLMAPI_RABBITMQ_USER_PASSWORD}" tags="management"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare vhost name="${WLMAPI_RABBITMQ_VHOST_NAME}"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare permission vhost="${WLMAPI_RABBITMQ_VHOST_NAME}" user="${WLMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"

else
  # SSL is not enabled, omit --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare user name="${WLMAPI_RABBITMQ_USER_NAME}" password="${WLMAPI_RABBITMQ_USER_PASSWORD}" tags="management"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare vhost name="${WLMAPI_RABBITMQ_VHOST_NAME}"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare permission vhost="${WLMAPI_RABBITMQ_VHOST_NAME}" user="${WLMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"
fi
