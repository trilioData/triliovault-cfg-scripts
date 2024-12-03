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

#### wlm api conf file
sleep 3m
source /tmp/triliovault-cloudrc
OS_SERVICE_DESC="TrilioVault Workloadmanager service"
# Get Service ID if it exists
unset OS_SERVICE_ID
CLOUD_ADMIN_USER_NAME="{{- .Values.keystone.common.cloud_admin_user_name -}}"
CLOUD_ADMIN_PROJECT_NAME="{{- .Values.keystone.common.cloud_admin_project_name -}}"
CLOUD_ADMIN_DOMAIN_NAME="{{- .Values.keystone.common.cloud_admin_domain_name -}}"
WLM_USER_NAME="{{- .Values.keystone.wlm_api.user -}}"

WLM_PROJECT_DOMAIN_NAME="{{- .Values.keystone.common.service_project_domain_name -}}"

WLM_PROJECT_NAME="{{- .Values.keystone.common.service_project_name -}}"

CLOUD_ADMIN_USER_ID=$(openstack user show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_USER_NAME}")

CLOUD_ADMIN_DOMAIN_ID=$(openstack domain show -f value -c id \
                "${CLOUD_ADMIN_DOMAIN_NAME}")

CLOUD_ADMIN_PROJECT_ID=$(openstack project show -f value -c id \
                "${CLOUD_ADMIN_PROJECT_NAME}")

WLM_PROJECT_DOMAIN_ID=$(openstack project show -f value -c domain_id \
                "${WLM_PROJECT_NAME}")

WLM_USER_ID=$(openstack user show -f value -c id \
                "${WLM_USER_NAME}")

WLM_USER_DOMAIN_ID=$(openstack user show -f value -c domain_id \
                "${WLM_USER_NAME}")


KEYSTONE_INTERFACE="{{- .Values.keystone.keystone_interface -}}"
NEUTRON_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service neutron -c URL -f value)
CINDER_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service cinderv3 -c URL -f value)
GLANCE_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service glance -c URL -f value)
KEYSTONE_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service keystone -c URL -f value)


if [[ $KEYSTONE_URL =~ ^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
  auth_protocol=${BASH_REMATCH[1]}
  auth_host=${BASH_REMATCH[2]}
  auth_port=${BASH_REMATCH[4]}
fi

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

chown nova:nova /tmp/pod-shared-${POD_NAME}/triliovault-wlm-dynamic.conf
mkdir -p /var/log/triliovault/wlm-api /var/log/triliovault/wlm-workloads /var/log/triliovault/wlm-scheduler
chown -R nova:nova /var/log/triliovault/

