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
#export RABBITMQ_URL="amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:${RABBITMQ_PORT}/"

# Add the RabbitMQ user
#rabbitmqctl add_user $DMAPI_RABBITMQ_USER_NAME $DMAPI_RABBITMQ_USER_PASSWORD

# Create the virtual host
#rabbitmqctl add_vhost $DMAPI_RABBITMQ_VHOST_NAME

#sleep 2s
# Set permissions for the user on the virtual host
#rabbitmqctl set_permissions -p $DMAPI_RABBITMQ_VHOST_NAME $DMAPI_RABBITMQ_USER_NAME ".*" ".*" ".*"

#echo "RabbitMQ user $DMAPI_RABBITMQ_USER_NAME and vhost $DMAPI_RABBITMQ_VHOST_NAME have been created with the specified permissions."
# Create user
rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
  --ssl declare user name="${DMAPI_RABBITMQ_USER_NAME}" password="${DMAPI_RABBITMQ_USER_PASSWORD}" tags="management"

# Create virtual host
rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
  --ssl declare vhost name="${DMAPI_RABBITMQ_VHOST_NAME}"

# Set permissions
rabbitmqadmin -H "$RABBITMQ_HOST" -P "$RABBITMQ_PORT" -u "$RABBITMQ_ADMIN_USER" -p "$RABBITMQ_ADMIN_PASSWORD" \
  --ssl declare permission vhost="${DMAPI_RABBITMQ_VHOST_NAME}" user="${DMAPI_RABBITMQ_USER_NAME}" configure=".*" write=".*" read=".*"
