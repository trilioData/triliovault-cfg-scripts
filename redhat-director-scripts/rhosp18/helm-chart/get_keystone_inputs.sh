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

AUTH_URI="${KEYSTONE_URL%/}/v3"

DMAPI_KEYSTONE_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_KEYSTONE_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`

# Generate TRILIOVAULT_WLM_AUTH_HOST_PUBLIC
TRILIOVAULT_WLM_AUTH_HOST_PUBLIC=$(echo "$AUTH_HOST_PUBLIC" | sed 's/keystone/triliovault-wlm/' | sed 's/openstack/triliovault/')

# Generate TRILIOVAULT_DM_AUTH_HOST_PUBLIC
TRILIOVAULT_DM_AUTH_HOST_PUBLIC=$(echo "$AUTH_HOST_PUBLIC" | sed 's/keystone/triliovault-dm/' | sed 's/openstack/triliovault/')


tee > ${SCRIPT_DIR}/trilio_inputs_keystone.yaml << EOF
keystone:
  common:
    auth_url: "$KEYSTONE_URL"
    auth_uri: "$AUTH_URI"
    keystone_auth_protocol: "$AUTH_PROTOCOL"
    keystone_auth_host: "$AUTH_HOST"
    keystone_auth_port: "$AUTH_PORT"
  datamover_api:
    password: $DMAPI_KEYSTONE_PASSWORD
    internal_endpoint: "${AUTH_PROTOCOL_INTERNAL}://triliovault-dm-internal.triliovault.svc:8784/v2"
    public_endpoint: "${AUTH_PROTOCOL_PUBLIC}://${TRILIOVAULT_DM_AUTH_HOST_PUBLIC}:8784/v2"
  wlm_api:
    password: $WLM_KEYSTONE_PASSWORD
    internal_endpoint: "${AUTH_PROTOCOL_INTERNAL}://triliovault-wlm-internal.triliovault.svc:8781/v1/\$(tenant_id)s"
    public_endpoint: "${AUTH_PROTOCOL_PUBLIC}://${TRILIOVAULT_WLM_AUTH_HOST_PUBLIC}:8781/v1/\$(tenant_id)s"
EOF

echo -e "Output written in file ${SCRIPT_DIR}/trilio_inputs_keystone.yaml"
