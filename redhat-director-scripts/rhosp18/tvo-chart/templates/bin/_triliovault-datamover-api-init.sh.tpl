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
USER_NAME="{{- .Values.keystone.datamover_api.user -}}"
PASSWORD="{{- .Values.keystone.datamover_api.password -}}"
SERVICE_DOMAIN="{{- .Values.keystone.common.service_project_domain_name -}}"
SERVICE_PROJECT="{{- .Values.keystone.common.service_project_name -}}"
ADMIN_ROLE_NAME="{{- .Values.keystone.common.admin_role_name -}}"
SERVICE_NAME="{{- .Values.keystone.datamover_api.service_name -}}"
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
  openstack service create --name $SERVICE_NAME --description "{{- .Values.keystone.datamover_api.service_desc -}}" "{{- .Values.keystone.datamover_api.service_type -}}"
  openstack endpoint create --region "{{- .Values.keystone.common.region_name -}}"  $SERVICE_NAME public "{{- .Values.keystone.datamover_api.public_endpoint -}}"
  openstack endpoint create --region "{{- .Values.keystone.common.region_name -}}" $SERVICE_NAME internal "{{- .Values.keystone.datamover_api.internal_endpoint -}}"
  openstack endpoint create --region "{{- .Values.keystone.common.region_name -}}" $SERVICE_NAME admin "{{- .Values.keystone.datamover_api.admin_endpoint -}}"

  echo "Service $SERVICE_NAME and its endpoints have been created."
fi



## datamover api conf file for my_ip parameter
chown -R dmapi:dmapi /var/log/triliovault
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-my-ip.conf
host_interface="{{- .Values.conf.my_ip.host_interface -}}"
if [[ -z $host_interface ]]; then
    # search for interface with default routing
    # If there is not default gateway, exit
    host_interface=$(ip -4 route list 0/0 | awk -F 'dev' '{ print $2; exit }' | awk '{ print $1 }') || exit 1
fi
datamover_api_ip_address=$(ip a s $host_interface | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}' | head -1)
if [ -z "${datamover_api_ip_address}" ] ; then
  echo "Var my_ip is empty"
  exit 1
fi

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-my-ip.conf << EOF
[DEFAULT]
dmapi_link_prefix = http://${datamover_api_ip_address}:8784
dmapi_listen = $datamover_api_ip_address
my_ip = $datamover_api_ip_address
EOF


## Database Resources Creation

# Database credentials
DB_ROOT_USER="{{- .Values.database.common.root_user_name -}}"
DB_ROOT_PASSWORD="{{- .Values.database.common.root_password -}}"
DB_HOST="{{- .Values.database.common.host_name -}}"
DB_NAME="{{- .Values.database.datamover_api.database -}}"
DB_USER="{{- .Values.database.datamover_api.user -}}"
DB_PASSWORD="{{- .Values.database.datamover_api.password -}}"
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
exec /var/lib/openstack/bin/python3 /usr/bin/dmapi-dbsync --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf


## Rabbitmq Resources Creation
# RabbitMQ server credentials and connection details
RABBITMQ_USER="{{- .Values.rabbitmq.common.admin_user-}}"
RABBITMQ_PASSWORD="{{- .Values.rabbitmq.common.admin_user-}}"
RABBITMQ_HOST="{{- .Values.rabbitmq.common.host-}}"
RABBITMQ_PORT="{{- .Values.rabbitmq.common.port-}}"

# RabbitMQ user to be created
DMAPI_RABBITMQ_USER_NAME="{{- .Values.rabbitmq.datamover_api.user-}}"
DMAPI_RABBITMQ_USER_PASSWORD="{{- .Values.rabbitmq.datamover_api.password-}}"
DMAPI_RABBITMQ_VHOST_NAME="{{- .Values.rabbitmq.datamover_api.vhost-}}"

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


## Any other init tasks

