#!/bin/bash -x
set -ex

if [ -z "$1" ]; then
  echo "Usage: $0 <keystone_interface>"
  exit 1
fi

KEYSTONE_INTERFACE=$1

# Retrieve the Keystone URL
KEYSTONE_URL=$(openstack endpoint list --interface $KEYSTONE_INTERFACE --service keystone -c URL -f value)

if [[ -z "$KEYSTONE_URL" ]]; then
  echo "Failed to retrieve Keystone URL"
  exit 1
fi

# Extract protocol, host, and port using regex
if [[ $KEYSTONE_URL =~ ^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
  AUTH_PROTOCOL=${BASH_REMATCH[1]}
  AUTH_HOST=${BASH_REMATCH[2]}
  AUTH_PORT=${BASH_REMATCH[4]}
else
  echo "Invalid Keystone URL"
fi

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


# Retrieve details of internal endpoint
KEYSTONE_URL_INTERNAL=$(openstack endpoint list --interface internal --service keystone -c URL -f value)
# Extract protocol, host, and port using regex
if [[ $KEYSTONE_URL_INTERNAL =~ ^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
  AUTH_PROTOCOL_INTERNAL=${BASH_REMATCH[1]}
  AUTH_HOST_INTERNAL=${BASH_REMATCH[2]}
else
  echo "Invalid Keystone URL"
fi

# Retrieve details of internal endpoint
KEYSTONE_URL_PUBLIC=$(openstack endpoint list --interface public --service keystone -c URL -f value)
# Extract protocol, host, and port using regex
if [[ $KEYSTONE_URL_PUBLIC =~ ^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
  AUTH_PROTOCOL_PUBLIC=${BASH_REMATCH[1]}
  AUTH_HOST_PUBLIC=${BASH_REMATCH[2]}
else
  echo "Invalid Keystone URL"
fi
# Retrieve details of internal endpoint
KEYSTONE_URL_ADMIN=$(openstack endpoint list --interface admin --service keystone -c URL -f value)
# Extract protocol, host, and port using regex
if [[ $KEYSTONE_URL_ADMIN =~ ^(https?)://([^:/]+)(:([0-9]+))?(/.*)?$ ]]; then
  AUTH_PROTOCOL_ADMIN=${BASH_REMATCH[1]}
  AUTH_HOST_ADMIN=${BASH_REMATCH[2]}
else
  echo "Invalid Keystone URL"
fi


DMAPI_RABBIT_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_RABBIT_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DMAPI_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DMAPI_KEYSTONE_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_KEYSTONE_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`

AUTH_URI="${KEYSTONE_URL%/}/v3"

tee > ${SCRIPT_DIR}/trilio_inputs_dynamic.yaml << EOF
database:
  datamover_api:
    password: $DMAPI_DB_PASSWORD
  wlm_api:
    password: $WLM_DB_PASSWORD
rabbitmq:
  datamover_api:
    password: $DMAPI_RABBIT_PASSWORD
  wlm_api:
    password: $WLM_RABBIT_PASSWORD
keystone:
  common:
    auth_url: "$KEYSTONE_URL"
    auth_uri: "$AUTH_URI"
    keystone_auth_protocol: "$AUTH_PROTOCOL"
    keystone_auth_host: "$AUTH_HOST"
    keystone_auth_port: "$AUTH_PORT"
  datamover_api:
    password: $DMAPI_KEYSTONE_PASSWORD
    internal_endpoint: "${AUTH_PROTOCOL_INTERNAL}://${AUTH_HOST_INTERNAL}:8784/v2"
    public_endpoint: "${AUTH_PROTOCOL_PUBLIC}://${AUTH_HOST_PUBLIC}:8784/v2"
    admin_endpoint: "${AUTH_PROTOCOL_ADMIN}://${AUTH_HOST_ADMIN}:8784/v2"
  wlm_api:
    password: $WLM_KEYSTONE_PASSWORD
    internal_endpoint: "${AUTH_PROTOCOL_INTERNAL}://${AUTH_HOST_INTERNAL}:8781/v1/\$(tenant_id)s"
    public_endpoint: "${AUTH_PROTOCOL_PUBLIC}://${AUTH_HOST_PUBLIC}:8781/v1/\$(tenant_id)s"
    admin_endpoint: "${AUTH_PROTOCOL_ADMIN}://${AUTH_HOST_ADMIN}:8781/v1/\$(tenant_id)s"
EOF

