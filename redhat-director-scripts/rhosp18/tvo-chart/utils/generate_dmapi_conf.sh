#!/bin/bash
set -ex


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${SCRIPT_DIR}/user_inputs
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




tee > ${SCRIPT_DIR}/../values_overrides/conf_datamover_api.yaml << EOF
conf:
  datamover_api:
    DEFAULT:
      transport_url: $DMAPI_TRANSPORT_URL
    database:
      connection: $DMAPI_DB_CONNECTION
    keystone_authtoken:
      memcached_servers: $MEMCACHED_SERVERS
      project_name: $SERVICE_PROJECT_NAME
      user_domain_name: $SERVICE_PROJECT_DOMAIN_NAME
      project_domain_name: $SERVICE_PROJECT_DOMAIN_NAME
      cafile: $CA_FILE
      password: $DMAPI_SERVICE_USER_PASSWORD
      auth_url: $KEYSTONE_AUTH_URL
      auth_uri: $KEYSTONE_AUTH_URI
    oslo_messaging_notifications:
      transport_url: $DMAPI_TRANSPORT_URL
EOF
