#!/bin/bash -x

set -ex
source /tmp/triliovault-cloudrc

# Variables
USER_NAME="{{- .Values.keystone.wlm_api.user -}}"
PASSWORD="{{- .Values.keystone.wlm_api.password -}}"
SERVICE_DOMAIN="{{- .Values.keystone.common.service_project_domain_name -}}"
SERVICE_PROJECT="{{- .Values.keystone.common.service_project_name -}}"
ADMIN_ROLE_NAME="{{- .Values.keystone.common.admin_role_name -}}"
SERVICE_NAME="{{- .Values.keystone.wlm_api.service_name -}}"
SERVICE_TYPE="{{- .Values.keystone.wlm_api.service_type -}}"
SERVICE_DESC="{{- .Values.keystone.wlm_api.service_desc -}}"
REGION_NAME="{{- .Values.keystone.common.region_name -}}"
PUBLIC_ENDPOINT='{{- .Values.keystone.wlm_api.public_endpoint -}}'
INTERNAL_ENDPOINT='{{- .Values.keystone.wlm_api.internal_endpoint -}}'

# Create keystone user if it does not exist
if openstack user list --domain $SERVICE_DOMAIN -f value -c Name | grep -qw $USER_NAME; then
  echo "User $USER_NAME already exists in domain $SERVICE_DOMAIN."
  openstack user set --password $PASSWORD $USER_NAME
else
  openstack user create --domain $SERVICE_DOMAIN --password $PASSWORD $USER_NAME
fi

# Assign role to the user
openstack role add --project $SERVICE_PROJECT --user $USER_NAME $ADMIN_ROLE_NAME

# Create keystone service if it does not exist
if openstack service list -f value -c Name | grep -qw $SERVICE_NAME; then
  echo "Service $SERVICE_NAME already exists."
else
  openstack service create --name $SERVICE_NAME --description "$SERVICE_DESC" "$SERVICE_TYPE"
fi

# Function to update or create endpoints
update_or_create_endpoint() {
  local INTERFACE=$1
  local ENDPOINT_URL=$2

  # Check if the endpoint exists
  ENDPOINT_ID=$(openstack endpoint list --service $SERVICE_NAME --interface $INTERFACE -c ID -f value)

  if [[ -n $ENDPOINT_ID ]]; then
    echo "$INTERFACE endpoint for $SERVICE_NAME exists. Updating to $ENDPOINT_URL."
    openstack endpoint set --url "$ENDPOINT_URL" "$ENDPOINT_ID"
  else
    echo "$INTERFACE endpoint for $SERVICE_NAME does not exist. Creating it."
    openstack endpoint create --region "$REGION_NAME" "$SERVICE_NAME" "$INTERFACE" "$ENDPOINT_URL"
  fi
}

# Update or create public and internal endpoints
update_or_create_endpoint "public" "$PUBLIC_ENDPOINT"
update_or_create_endpoint "internal" "$INTERNAL_ENDPOINT"

echo "Keystone user, service, and endpoints are configured successfully."

