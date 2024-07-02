#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

## Keystone Resources Creation
USER_NAME="{{- .Values.keystone.wlm_api.user -}}"
PASSWORD="{{- .Values.keystone.wlm_api.password -}}"
SERVICE_DOMAIN="{{- .Values.keystone.common.service_project_domain_name -}}"
SERVICE_PROJECT="{{- .Values.keystone.common.service_project_name -}}"
ADMIN_ROLE_NAME="{{- .Values.keystone.common.admin_role_name -}}"
SERVICE_NAME="{{- .Values.keystone.wlm_api.service_name -}}"
REGION_NAME="{{- .Values.keystone.common.region_name -}}"
## Create keystone user if it does not exists
if openstack user list --domain $SERVICE_DOMAIN -f value -c Name | grep -qw $USER_NAME; then
  echo "User $USER_NAME already exists in domain $SERVICE_DOMAIN."
else
  openstack user create --domain $SERVICE_DOMAIN --password $PASSWORD $USER_NAME
fi
openstack role add --project $SERVICE_PROJECT --user $USER_NAME $ADMIN_ROLE_NAME

# Create keystone service if it does not exists
if openstack service list -f value -c Name | grep -qw $SERVICE_NAME; then
  echo "Service $SERVICE_NAME already exists."
else
  # Create the service if it does not exist
  openstack service create --name $SERVICE_NAME --description "{{- .Values.keystone.wlm_api.service_desc -}}" "{{- .Values.keystone.wlm_api.service_type -}}"
  openstack endpoint create --region $REGION_NAME $SERVICE_NAME public "{{- .Values.keystone.wlm_api.public_endpoint -}}"
  openstack endpoint create --region $REGION_NAME $SERVICE_NAME internal "{{- .Values.keystone.wlm_api.internal_endpoint -}}"
  openstack endpoint create --region $REGION_NAME $SERVICE_NAME admin "{{- .Values.keystone.wlm_api.admin_endpoint -}}"

  echo "Service $SERVICE_NAME and its endpoints have been created."
fi

## Database Resources Creation

# Database credentials
DB_ROOT_USER="{{- .Values.database.common.root_user_name -}}"
DB_ROOT_PASSWORD="{{- .Values.database.common.root_password -}}"
DB_HOST="{{- .Values.database.common.host_name -}}"
DB_NAME="{{- .Values.database.wlm_api.database -}}"
DB_USER="{{- .Values.database.wlm_api.user -}}"
DB_PASSWORD="{{- .Values.database.wlm_api.password -}}"
# Create the database
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# Create the user
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"

# Grant privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';"
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
# Flush privileges
mysql -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -h "$DB_HOST" -e "FLUSH PRIVILEGES;"

# Database Sync
exec alembic --config /etc/triliovault-wlm/triliovault-wlm.conf upgrade head

## Rabbitmq Resources Creation
# RabbitMQ server credentials and connection details
RABBITMQ_USER="{{- .Values.rabbitmq.common.admin_user -}}"
RABBITMQ_PASSWORD="{{- .Values.rabbitmq.common.admin_user -}}"
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host -}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port -}}"

# RabbitMQ user to be created
DMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.wlm_api.user -}}"
DMAPI_RABBITMQ_USER_PASSWORD="{{- .Values.rabbitmq.wlm_api.password -}}"
DMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.wlm_api.vhost -}}"

# Export credentials for rabbitmqctl
export RABBITMQ_USER
export RABBITMQ_PASSWORD
export RABBITMQ_URL="amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@${RABBITMQ_HOST}:${RABBITMQ_PORT}/"

# Add the RabbitMQ user
rabbitmqctl add_user $DMAPI_RABBITMQ_USER_NAME $DMAPI_RABBITMQ_USER_PASSWORD

# Create the virtual host
rabbitmqctl add_vhost $DMAPI_RABBITMQ_VHOST_NAME

# Set permissions for the user on the virtual host
rabbitmqctl set_permissions -p $DMAPI_RABBITMQ_VHOST_NAME $DMAPI_RABBITMQ_USER_NAME ".*" ".*" ".*"

echo "RabbitMQ user $DMAPI_RABBITMQ_USER_NAME and vhost $DMAPI_RABBITMQ_VHOST_NAME have been created with the specified permissions."



#### wlm api conf file

# Service boilerplate description
OS_SERVICE_DESC="${OS_REGION_NAME}: ${OS_SERVICE_NAME} (${OS_SERVICE_TYPE}) service"
# Get Service ID if it exists
unset OS_SERVICE_ID
CLOUD_ADMIN_USER_NAME="{{- .Values.keystone.common.cloud_admin_user_name -}}"
CLOUD_ADMIN_PROJECT_NAME="{{- .Values.keystone.common.cloud_admin_project_name -}}"
CLOUD_ADMIN_DOMAIN_NAME="{{- Values.keystone.common.cloud_admin_domain_name -}}"
WLM_USER_NAME="{{- Values.keystone.wlm_api.user-}}"

WLM_PROJECT_DOMAIN_NAME="{{- .Values.keystone.common.service_project_domain_name -}}"

WLM_PROJECT_NAME="{{- .Values.keystone.common.service_project_name-}}"

CLOUD_ADMIN_USER_ID=$(openstack user show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_USER_NAME}")

CLOUD_ADMIN_DOMAIN_ID=$(openstack domain show -f value -c id \
                "${CLOUD_ADMIN_DOMAIN_NAME}")

CLOUD_ADMIN_PROJECT_ID=$(openstack project show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_PROJECT_NAME}")

WLM_PROJECT_DOMAIN_ID=$(openstack project show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id \
                "${WLM_PROJECT_NAME}")

WLM_USER_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c id \
                "${WLM_USER_NAME}")

WLM_USER_DOMAIN_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id \
                "${WLM_USER_NAME}")


host_interface=$(ip -4 route list 0/0 | awk -F 'dev' '{ print $2; exit }' | awk '{ print $1 }') || exit 1

POD_IP=$(ip a s $host_interface | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}' | head -1)

KEYSTONE_INTERFACE="{{- .Values.keystone.keystone_interface -}}"
NEUTRON_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service neutron -c URL -f value)
CINDER_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service cinderv3 -c URL -f value)
GLANCE_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service glance -c URL -f value)
KEYSTONE_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service keystone -c URL -f value)


tee > /tmp/pod-shared-${POD_NAME}/triliovault-wlm-dynamic.conf << EOF
[DEFAULT]

neutron_production_url =  $NEUTRON_URL
nova_production_endpoint_template = ${NOVA_URL}%(project_id)s
cinder_production_endpoint_template = $CINDER_URL
glance_production_api_servers = $GLANCE_URL
keystone_endpoint_url = $KEYSTONE_URL
neutron_admin_auth_url = $KEYSTONE_URL
nova_admin_auth_url = $KEYSTONE_URL

triliovault_hostnames = ${POD_IP}
cloud_admin_user_id = $CLOUD_ADMIN_USER_ID
cloud_admin_domain = $CLOUD_ADMIN_DOMAIN_ID
cloud_admin_project_id = $CLOUD_ADMIN_PROJECT_ID
cloud_unique_id = $WLM_USER_ID
triliovault_user_domain_id = $WLM_USER_DOMAIN_ID
domain_name = $CLOUD_ADMIN_DOMAIN_ID

[keystone_authtoken]
project_domain_id = $WLM_PROJECT_DOMAIN_ID
user_domain_id = $WLM_USER_DOMAIN_ID

EOF

chown nova:nova /tmp/pod-shared-${POD_NAME}/triliovault-wlm-ids.conf
mkdir -p /var/log/triliovault/wlm-api /var/log/triliovault/wlm-workloads /var/log/triliovault/wlm-scheduler
chown -R nova:nova /var/log/triliovault/
