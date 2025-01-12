#!/bin/bash -x
set -ex
RABBITMQ_ADMIN_USER="{{- .Values.rabbitmq.common.admin_user -}}"
RABBITMQ_ADMIN_PASSWORD="{{- .Values.rabbitmq.common.admin_password -}}"
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"

# RabbitMQ user to be created
DMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.datamover_api.user -}}"
DMAPI_RABBITMQ_USER_PASSWORD="{{- .Values.rabbitmq.datamover_api.password -}}"
DMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.datamover_api.vhost -}}"

# Export credentials for rabbitmqctl
export RABBITMQ_ADMIN_USER
export RABBITMQ_ADMIN_PASSWORD


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