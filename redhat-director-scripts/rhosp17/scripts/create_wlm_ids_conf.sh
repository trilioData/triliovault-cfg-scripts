#!/bin/bash
set -ex

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


## User Input
CLOUD_ADMIN_USER_NAME=`grep "CloudAdminUserName" ${SCRIPT_DIR}/../environments/trilio_env.yaml | awk -F ":" '{print $2}' | tr -d ' ' | tr -d \'\"`
CLOUD_ADMIN_PROJECT_NAME=`grep "CloudAdminProjectName" ${SCRIPT_DIR}/../environments/trilio_env.yaml | awk -F ":" '{print $2}' | tr -d ' ' | tr -d \'\"`
CLOUD_ADMIN_DOMAIN_NAME=`grep "CloudAdminDomainName" ${SCRIPT_DIR}/../environments/trilio_env.yaml | awk -F ":" '{print $2}' | tr -d ' ' | tr -d \'\"`
WLM_PROJECT_DOMAIN_NAME=`grep "TriliovaultKeystoneUserDomainName" ${SCRIPT_DIR}/../environments/defaults.yaml | awk -F ":" '{print $2}' | tr -d ' ' | tr -d \'\"`
WLM_PROJECT_NAME=`grep "TriliovaultKeystoneServiceProjectName" ${SCRIPT_DIR}/../environments/defaults.yaml | awk -F ":" '{print $2}' | tr -d ' ' | tr -d \'\"`


## Fetch ids
CLOUD_ADMIN_USER_ID=$(openstack user show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_USER_NAME}")

CLOUD_ADMIN_DOMAIN_ID=$(openstack domain show -f value -c id \
                "${CLOUD_ADMIN_DOMAIN_NAME}")

CLOUD_ADMIN_PROJECT_ID=$(openstack project show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_PROJECT_NAME}")

WLM_PROJECT_DOMAIN_ID=$(openstack project show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id \
                "${WLM_PROJECT_NAME}")

WLM_USER_DOMAIN_ID=$(openstack domain show -f value -c id \
                "${WLM_PROJECT_DOMAIN_NAME}")

tee > ${SCRIPT_DIR}/../puppet/trilio/files/triliovault_wlm_ids.conf << EOF
[DEFAULT]
cloud_admin_user_id = $CLOUD_ADMIN_USER_ID
cloud_admin_domain = $CLOUD_ADMIN_DOMAIN_ID
cloud_admin_project_id = $CLOUD_ADMIN_PROJECT_ID
triliovault_user_domain_id = $WLM_USER_DOMAIN_ID
domain_name = $CLOUD_ADMIN_DOMAIN_ID

[keystone_authtoken]
project_domain_id = $WLM_PROJECT_DOMAIN_ID
user_domain_id = $WLM_USER_DOMAIN_ID

EOF
