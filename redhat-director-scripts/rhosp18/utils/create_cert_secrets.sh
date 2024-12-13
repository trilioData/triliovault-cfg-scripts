#!/bin/bash

oc create -f ./certificate.yaml

oc get secret cert-triliovault-wlm-public-svc -n openstack -o yaml > cert-triliovault-wlm-public-svc.yaml
oc get secret cert-triliovault-wlm-internal-svc -n openstack -o yaml > cert-triliovault-wlm-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-wlm-public-svc.yaml

oc create -f cert-triliovault-wlm-public-svc.yaml
oc create -f cert-triliovault-wlm-internal-svc.yaml

oc describe secret cert-triliovault-wlm-public-svc -n trilio-openstack
oc describe secret cert-triliovault-wlm-internal-svc -n trilio-openstack


oc get secret cert-triliovault-datamover-public-svc -n openstack -o yaml > cert-triliovault-datamover-public-svc.yaml
oc get secret cert-triliovault-datamover-internal-svc -n openstack -o yaml > cert-triliovault-datamover-internal-svc.yaml

sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-internal-svc.yaml
sed -i 's/openstack/trilio-openstack/' cert-triliovault-datamover-public-svc.yaml

oc create -f cert-triliovault-datamover-public-svc.yaml
oc create -f cert-triliovault-datamover-internal-svc.yaml

oc describe secret cert-triliovault-datamover-public-svc -n trilio-openstack
oc describe secret cert-triliovault-datamover-internal-svc -n trilio-openstack

#sleep 15s
#oc -n openstack delete secret cert-triliovault-datamover-internal-svc  \
#  cert-triliovault-datamover-public-svc cert-triliovault-wlm-internal-svc cert-triliovault-wlm-public-svc

#!/bin/bash

# Define variables
SOURCE_NAMESPACE="openstack"
TARGET_NAMESPACE="trilio-openstack"
SECRET_NAME="combined-ca-bundle"

# Check if the secret exists in the source namespace
if ! kubectl get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" > /dev/null 2>&1; then
  echo "Error: Secret '$SECRET_NAME' does not exist in namespace '$SOURCE_NAMESPACE'"
  exit 1
fi

# Extract and decode specific data items from the secret
INTERNAL_CA_BUNDLE=$(kubectl get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" -o jsonpath='{.data.internal-ca-bundle\.pem}' | base64 -d)
TLS_CA_BUNDLE=$(kubectl get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" -o jsonpath='{.data.tls-ca-bundle\.pem}' | base64 -d)

# Check if data items were retrieved successfully
if [[ -z "$INTERNAL_CA_BUNDLE" || -z "$TLS_CA_BUNDLE" ]]; then
  echo "Error: Failed to fetch and decode required data from the secret '$SECRET_NAME'."
  exit 1
fi

# Create a temporary directory for the decoded files
TEMP_DIR=$(mktemp -d)
echo "$INTERNAL_CA_BUNDLE" > "$TEMP_DIR/internal-ca-bundle.pem"
echo "$TLS_CA_BUNDLE" > "$TEMP_DIR/tls-ca-bundle.pem"

# Delete any existing secret in the target namespace
kubectl delete secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" 2>/dev/null || true

# Create a new secret in the target namespace using the decoded files
kubectl create secret generic "$SECRET_NAME" -n "$TARGET_NAMESPACE" \
  --from-file=internal-ca-bundle.pem="$TEMP_DIR/internal-ca-bundle.pem" \
  --from-file=tls-ca-bundle.pem="$TEMP_DIR/tls-ca-bundle.pem"

# Clean up the temporary directory
rm -rf "$TEMP_DIR"

if [ $? -eq 0 ]; then
  echo "Secret '$SECRET_NAME' has been successfully created in namespace '$TARGET_NAMESPACE'."
else
  echo "Error: Failed to create the secret in namespace '$TARGET_NAMESPACE'."
  exit 1
fi

