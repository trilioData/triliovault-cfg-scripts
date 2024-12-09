#!/bin/bash -x
set -ex
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

DMAPI_RABBIT_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_RABBIT_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DMAPI_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`

RABBIT_HOST=`oc -n openstack get secret rabbitmq-default-user -o jsonpath='{.data.host}' | base64 --decode`
RABBIT_PORT=`oc -n openstack get secret rabbitmq-default-user -o jsonpath='{.data.port}' | base64 --decode`
RABBIT_DRIVER=$(oc -n openstack get secret nova-api-config-data -o jsonpath='{.data.01-nova\.conf}' | base64 --decode | grep "^driver" | awk -F"=" '{print $2}' | xargs)
DB_ROOT_PASSWORD=`oc -n openstack get secret osp-secret -o jsonpath='{.data.DbRootPassword}' | base64 --decode`
DB_HOST=`oc -n openstack get secret nova-api-config-data -o jsonpath='{.data.01-nova\.conf}' | base64 --decode | awk '/connection =/ {match($0, /@([^?\/]+)/, arr); print arr[1]; exit}'`
DB_PORT="3306"
RABBIT_ADMIN_PASSWORD=""


MEMCACHED_SERVERS=`oc -n openstack get memcached -o jsonpath='{.items[*].status.serverList[*]}' | tr ' ' ','`
KEYSTONE_CA_CERT=`oc -n openstack get secret rootca-internal -o jsonpath='{.data.ca\.crt}' | base64 --decode`
TRANSPORT_URL=`oc -n openstack get secret rabbitmq-transport-url-cinder-cinder-transport -o jsonpath='{.data.transport_url}' | base64 --decode`

tee > ${SCRIPT_DIR}/trilio_inputs_dynamic.yaml << EOF
apiVersion: tvo.trilio.io/v1
kind: TVOControlPlane
spec:
  common:
    memcached_servers: $MEMCACHED_SERVERS
  database:
    common:
      root_user_name: "root"
      root_password: $DB_ROOT_PASSWORD
      host: $DB_HOST
      port: $DB_PORT
    datamover_api:
      password: $DMAPI_DB_PASSWORD
    wlm_api:
      password: $WLM_DB_PASSWORD
  rabbitmq:
    common: 
      admin_user: "rabbitmq"
      admin_password: $RABBIT_ADMIN_PASSWORD
      host: $RABBIT_HOST
      port: $RABBIT_PORT
      driver: $RABBIT_DRIVER
    datamover_api:
      transport_url: $TRANSPORT_URL
      password: $DMAPI_RABBIT_PASSWORD
    wlm_api:
      transport_url: $TRANSPORT_URL
      password: $WLM_RABBIT_PASSWORD
  keystone:
    common:
      ca_cert: |
  $(echo "$KEYSTONE_CA_CERT" | sed 's/^/      /')
EOF

echo -e "Dynamic values are generated and copied to file ${SCRIPT_DIR}/tvo-chart/values_overrides/trilio_inputs_dynamic.yaml"
