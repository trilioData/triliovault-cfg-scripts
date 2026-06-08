#!/bin/bash

# Use this script when RHOSO is configured with a wildcard TLS certificate that
# already covers both OpenStack and Trilio service DNS names.
# It copies the wildcard cert secret from the 'openstack' namespace to the
# 'trilio-openstack' namespace under all the secret names Trilio expects.
#
# Usage: ./create_wildcard_cert_secrets.sh <wildcard-secret-name> <ca-bundle-secret-name>
# Example: ./create_wildcard_cert_secrets.sh <openstack-wildcard-cert-secret-name> <ca-bundle-secret-name>
#
# Arguments:
#   <wildcard-secret-name>  : Name of the wildcard TLS secret in the 'openstack' namespace
#   <ca-bundle-secret-name> : Name of the CA bundle secret in the 'openstack' namespace.
#                             If found, it is copied to 'trilio-openstack' as 'combined-ca-bundle'.
#                             If not found, a message is printed and the script continues.
#
# Pre-requisite: The wildcard certificate must already include the following DNS names
# (PUBLIC_ENDPOINT_DOMAIN is auto-detected from the openstackclient pod):
#   *.trilio-openstack.svc
#   *.trilio-openstack.svc.cluster.local
#   *.<PUBLIC_ENDPOINT_DOMAIN>
#   *.trilio-rabbitmq-cluster-nodes.trilio-openstack

set -e

if [[ -z "$1" || -z "$2" ]]; then
  echo "Usage: $0 <wildcard-secret-name> <ca-bundle-secret-name>"
  echo "  <wildcard-secret-name>  : Name of the wildcard TLS secret in the 'openstack' namespace"
  echo "  <ca-bundle-secret-name> : Name of the CA bundle secret in the 'openstack' namespace"
  exit 1
fi

WILDCARD_SECRET_NAME="$1"
CA_BUNDLE_INPUT_SECRET="$2"
SOURCE_NAMESPACE="openstack"
TARGET_NAMESPACE="trilio-openstack"

# ── Auto-detect PUBLIC_ENDPOINT_DOMAIN ────────────────────────────────────────
echo "Detecting PUBLIC_ENDPOINT_DOMAIN from openstackclient pod..."

OC_POD=$(oc get pod -n "$SOURCE_NAMESPACE" -l app=openstackclient \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$OC_POD" ]]; then
  echo "Error: openstackclient pod not found in '$SOURCE_NAMESPACE' namespace"
  exit 1
fi

ENDPOINT_URL=$(oc exec -n "$SOURCE_NAMESPACE" "$OC_POD" -- \
  openstack endpoint list --interface public --service identity -f value -c URL \
  2>/dev/null | head -1)

if [[ -z "$ENDPOINT_URL" ]]; then
  echo "Error: Failed to retrieve public Keystone endpoint URL from openstackclient pod"
  exit 1
fi

# Extract domain: https://keystone-public-openstack.apps.example.com:5000 -> apps.example.com
HOSTNAME=$(echo "$ENDPOINT_URL" | sed 's|https://||;s|/.*||;s|:.*||')
PUBLIC_ENDPOINT_DOMAIN=$(echo "$HOSTNAME" | cut -d'.' -f2-)

echo "Detected PUBLIC_ENDPOINT_DOMAIN: $PUBLIC_ENDPOINT_DOMAIN"
echo ""
echo "The wildcard certificate must cover the following Trilio DNS names:"
echo "  *.trilio-openstack.svc"
echo "  *.trilio-openstack.svc.cluster.local"
echo "  *.$PUBLIC_ENDPOINT_DOMAIN"
echo "  *.trilio-rabbitmq-cluster-nodes.trilio-openstack"
echo ""

# ── Validate wildcard secret exists ───────────────────────────────────────────
if ! oc get secret "$WILDCARD_SECRET_NAME" -n "$SOURCE_NAMESPACE" > /dev/null 2>&1; then
  echo "Error: Secret '$WILDCARD_SECRET_NAME' not found in namespace '$SOURCE_NAMESPACE'"
  exit 1
fi

echo "Using wildcard certificate secret: $WILDCARD_SECRET_NAME"
echo "Source namespace: $SOURCE_NAMESPACE"
echo "Target namespace: $TARGET_NAMESPACE"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# ── Extract TLS cert and key from the wildcard secret ─────────────────────────
oc get secret "$WILDCARD_SECRET_NAME" -n "$SOURCE_NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TEMP_DIR/tls.crt"

oc get secret "$WILDCARD_SECRET_NAME" -n "$SOURCE_NAMESPACE" \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$TEMP_DIR/tls.key"

# Extract CA cert if present in the wildcard secret
CA_CRT=$(oc get secret "$WILDCARD_SECRET_NAME" -n "$SOURCE_NAMESPACE" \
  -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
if [[ -n "$CA_CRT" ]]; then
  echo "$CA_CRT" | base64 -d > "$TEMP_DIR/ca.crt"
fi

# ── Create all Trilio cert secrets in trilio-openstack ────────────────────────
TRILIO_CERT_SECRETS=(
  "cert-triliovault-wlm-public-svc"
  "cert-triliovault-wlm-internal-svc"
  "cert-triliovault-datamover-public-svc"
  "cert-triliovault-datamover-internal-svc"
  "cert-trilio-rabbitmq-cluster"
  "cert-trilio-galera-cluster"
)

for SECRET_NAME in "${TRILIO_CERT_SECRETS[@]}"; do
  echo ""
  echo "Creating secret '$SECRET_NAME' in '$TARGET_NAMESPACE'..."

  oc delete secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" 2>/dev/null || true

  oc create secret tls "$SECRET_NAME" -n "$TARGET_NAMESPACE" \
    --cert="$TEMP_DIR/tls.crt" \
    --key="$TEMP_DIR/tls.key"

  if [[ -f "$TEMP_DIR/ca.crt" ]]; then
    oc patch secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" \
      --type='json' \
      -p="[{\"op\": \"add\", \"path\": \"/data/ca.crt\", \"value\": \"$(base64 -w0 "$TEMP_DIR/ca.crt")\"}]"
  fi

  oc describe secret "$SECRET_NAME" -n "$TARGET_NAMESPACE"
done

# ── Copy CA bundle to trilio-openstack as combined-ca-bundle ──────────────────
echo ""
echo "Checking for CA bundle secret '$CA_BUNDLE_INPUT_SECRET' in '$SOURCE_NAMESPACE'..."

if ! oc get secret "$CA_BUNDLE_INPUT_SECRET" -n "$SOURCE_NAMESPACE" > /dev/null 2>&1; then
  echo "Secret '$CA_BUNDLE_INPUT_SECRET' does not exist in '$SOURCE_NAMESPACE'. Skipping combined-ca-bundle creation."
else
  INTERNAL_CA_BUNDLE=$(oc get secret "$CA_BUNDLE_INPUT_SECRET" -n "$SOURCE_NAMESPACE" \
    -o jsonpath='{.data.internal-ca-bundle\.pem}' | base64 -d)
  TLS_CA_BUNDLE=$(oc get secret "$CA_BUNDLE_INPUT_SECRET" -n "$SOURCE_NAMESPACE" \
    -o jsonpath='{.data.tls-ca-bundle\.pem}' | base64 -d)

  if [[ -z "$INTERNAL_CA_BUNDLE" || -z "$TLS_CA_BUNDLE" ]]; then
    echo "Secret '$CA_BUNDLE_INPUT_SECRET' found but could not extract expected data. Skipping combined-ca-bundle creation."
  else
    echo "$INTERNAL_CA_BUNDLE" > "$TEMP_DIR/internal-ca-bundle.pem"
    echo "$TLS_CA_BUNDLE" > "$TEMP_DIR/tls-ca-bundle.pem"

    oc delete secret "combined-ca-bundle" -n "$TARGET_NAMESPACE" 2>/dev/null || true

    oc create secret generic "combined-ca-bundle" -n "$TARGET_NAMESPACE" \
      --from-file=internal-ca-bundle.pem="$TEMP_DIR/internal-ca-bundle.pem" \
      --from-file=tls-ca-bundle.pem="$TEMP_DIR/tls-ca-bundle.pem"

    echo "Secret 'combined-ca-bundle' created in '$TARGET_NAMESPACE'."
  fi
fi

echo ""
echo "All Trilio certificate secrets created successfully in '$TARGET_NAMESPACE'."
echo "Note: certificate.yaml (cert-manager) is not required when using a wildcard certificate."
