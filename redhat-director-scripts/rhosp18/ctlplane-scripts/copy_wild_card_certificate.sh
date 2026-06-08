#!/bin/bash

# Use this script when RHOSO is configured with a wildcard TLS certificate that
# already covers both OpenStack and Trilio service DNS names.
# It copies the wildcard cert secret from the 'openstack' namespace to the
# 'trilio-openstack' namespace under all the secret names Trilio expects.
#
# Usage: ./copy_wild_card_certificate.sh <wildcard-secret-name>
# Example: ./copy_wild_card_certificate.sh <openstack-wildcard-cert-secret-name>
#
# Arguments:
#   <wildcard-secret-name>  : Name of the wildcard TLS secret in the 'openstack' namespace
#
# Pre-requisite: The wildcard certificate must already include the following DNS names:
#   *.trilio-openstack.svc
#   *.trilio-openstack.svc.cluster.local
#   *.<PUBLIC_ENDPOINT_DOMAIN>
#   *.trilio-rabbitmq-cluster-nodes.trilio-openstack

set -e

if [[ -z "$1" ]]; then
  echo "Usage: $0 <wildcard-secret-name>"
  echo "  <wildcard-secret-name>  : Name of the wildcard TLS secret in the 'openstack' namespace"
  exit 1
fi

WILDCARD_SECRET_NAME="$1"
SOURCE_NAMESPACE="openstack"
TARGET_NAMESPACE="trilio-openstack"
CA_BUNDLE_SECRET="combined-ca-bundle"
OC_POD="openstackclient"

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

  oc describe secret "$SECRET_NAME" -n "$TARGET_NAMESPACE"
done

# ── Copy CA bundle to trilio-openstack as combined-ca-bundle ──────────────────
echo ""
echo "Checking for CA bundle secret '$CA_BUNDLE_SECRET' in '$SOURCE_NAMESPACE'..."

if ! oc get secret "$CA_BUNDLE_SECRET" -n "$SOURCE_NAMESPACE" > /dev/null 2>&1; then
  echo "INFO: Secret '$CA_BUNDLE_SECRET' was NOT found in '$SOURCE_NAMESPACE' namespace."
  echo "      This is expected when using a certificate signed by a public CA."
  echo "      Extracting system CA bundle from openstackclient pod to create 'combined-ca-bundle'..."

  oc exec -n "$SOURCE_NAMESPACE" "$OC_POD" -- \
    cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem > "$TEMP_DIR/tls-ca-bundle.pem"

  if [[ ! -s "$TEMP_DIR/tls-ca-bundle.pem" ]]; then
    echo "WARNING: Failed to extract CA bundle from openstackclient pod '$OC_POD'."
    echo "         Create 'combined-ca-bundle' manually in '$TARGET_NAMESPACE'."
  else
    oc delete secret "combined-ca-bundle" -n "$TARGET_NAMESPACE" 2>/dev/null || true

    oc create secret generic "combined-ca-bundle" -n "$TARGET_NAMESPACE" \
      --from-file=internal-ca-bundle.pem="$TEMP_DIR/tls-ca-bundle.pem" \
      --from-file=tls-ca-bundle.pem="$TEMP_DIR/tls-ca-bundle.pem"

    echo "INFO: Secret 'combined-ca-bundle' created in '$TARGET_NAMESPACE' using system CA bundle"
    echo "      extracted from openstackclient pod '$OC_POD' in '$SOURCE_NAMESPACE' namespace."
  fi
else
  echo "INFO: Secret '$CA_BUNDLE_SECRET' found in '$SOURCE_NAMESPACE' namespace."
  echo "      This indicates RHOSO is using an internal/self-signed CA."
  echo "      Copying '$CA_BUNDLE_SECRET' from '$SOURCE_NAMESPACE' to '$TARGET_NAMESPACE'..."

  INTERNAL_CA_BUNDLE=$(oc get secret "$CA_BUNDLE_SECRET" -n "$SOURCE_NAMESPACE" \
    -o jsonpath='{.data.internal-ca-bundle\.pem}' | base64 -d)
  TLS_CA_BUNDLE=$(oc get secret "$CA_BUNDLE_SECRET" -n "$SOURCE_NAMESPACE" \
    -o jsonpath='{.data.tls-ca-bundle\.pem}' | base64 -d)

  if [[ -z "$INTERNAL_CA_BUNDLE" || -z "$TLS_CA_BUNDLE" ]]; then
    echo "WARNING: Secret '$CA_BUNDLE_SECRET' found but could not extract 'internal-ca-bundle.pem'"
    echo "         or 'tls-ca-bundle.pem' data. Skipping combined-ca-bundle creation."
  else
    echo "$INTERNAL_CA_BUNDLE" > "$TEMP_DIR/internal-ca-bundle.pem"
    echo "$TLS_CA_BUNDLE" > "$TEMP_DIR/tls-ca-bundle.pem"

    oc delete secret "combined-ca-bundle" -n "$TARGET_NAMESPACE" 2>/dev/null || true

    oc create secret generic "combined-ca-bundle" -n "$TARGET_NAMESPACE" \
      --from-file=internal-ca-bundle.pem="$TEMP_DIR/internal-ca-bundle.pem" \
      --from-file=tls-ca-bundle.pem="$TEMP_DIR/tls-ca-bundle.pem"

    echo "INFO: Secret 'combined-ca-bundle' successfully copied from '$SOURCE_NAMESPACE'"
    echo "      to '$TARGET_NAMESPACE' namespace."
  fi
fi

echo ""
echo "All Trilio certificate secrets created successfully in '$TARGET_NAMESPACE'."
echo "Note: certificate.yaml (cert-manager) is not required when using a wildcard certificate."
