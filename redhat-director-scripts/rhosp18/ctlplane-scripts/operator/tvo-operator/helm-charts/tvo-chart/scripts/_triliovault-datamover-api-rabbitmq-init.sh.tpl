#!/bin/bash
set -e
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"

# RabbitMQ user to be created
DMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.datamover_api.user -}}"

DMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.datamover_api.vhost -}}"

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
# Check if SSL is enabled and run the corresponding commands
if [ "{{- .Values.rabbitmq.common.ssl -}}" == "true" ]; then
  # SSL is enabled, include --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare user name="${DMAPI_RABBITMQ_USER_NAME}" password="${DMAPI_RABBITMQ_USER_PASSWORD}" tags="management"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare vhost name="${DMAPI_RABBITMQ_VHOST_NAME}"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" --ssl \
    declare permission vhost="${DMAPI_RABBITMQ_VHOST_NAME}" user="${DMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"

else
  # SSL is not enabled, omit --ssl in commands
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare user name="${DMAPI_RABBITMQ_USER_NAME}" password="${DMAPI_RABBITMQ_USER_PASSWORD}" tags="management"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare vhost name="${DMAPI_RABBITMQ_VHOST_NAME}"
  
  rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
    declare permission vhost="${DMAPI_RABBITMQ_VHOST_NAME}" user="${DMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"
fi