#!/bin/bash
# TVAULT-7493: update the Galera Certificate's DNS SAN to match the renamed CR
# (trilio-db-cluster), apply it, and copy the reissued cert secret into the
# trilio-openstack namespace. Scoped to the Galera cert only -- does not
# touch WLM/DataMover/RabbitMQ certs, and does not restart any deployments
# (unlike renew_certs.sh, which does both and is not safe to run mid-migration).
set -euo pipefail

CERT_FILE="certificate.yaml"
OLD_HOST="trilio-galera-cluster.trilio-openstack.svc"
NEW_HOST="trilio-db-cluster.trilio-openstack.svc"
SECRET_NAME="cert-trilio-galera-cluster"
SOURCE_NAMESPACE="openstack"
TARGET_NAMESPACE="trilio-openstack"

echo "==> Updating Galera cert DNS SAN in $CERT_FILE ($OLD_HOST -> $NEW_HOST)..."
sed -i "s/${OLD_HOST}/${NEW_HOST}/g" "$CERT_FILE"
grep -n "$NEW_HOST" "$CERT_FILE" || {
  echo "ERROR: $NEW_HOST not found in $CERT_FILE after update -- aborting." >&2
  exit 1
}

echo ""
echo "==> Applying $CERT_FILE to namespace $SOURCE_NAMESPACE..."
APPLY_OUTPUT=$(oc apply -n "$SOURCE_NAMESPACE" -f "$CERT_FILE")
echo "$APPLY_OUTPUT"

if echo "$APPLY_OUTPUT" | grep -q "certificate.cert-manager.io/trilio-galera-cluster \(configured\|created\)"; then
  echo ""
  echo "==> Change detected for the Galera certificate -- waiting 60s for cert-manager to reissue..."
  sleep 60
else
  echo ""
  echo "==> No change detected for the Galera certificate -- skipping reissue wait."
fi

echo ""
echo "==> Verifying reissued cert SAN in $SOURCE_NAMESPACE..."
oc get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"

if ! oc get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -q "$NEW_HOST"; then
  echo "ERROR: reissued cert in $SOURCE_NAMESPACE does not contain the new SAN ($NEW_HOST) yet. Try re-running after waiting longer for cert-manager." >&2
  exit 1
fi

echo ""
echo "==> Copying $SECRET_NAME from $SOURCE_NAMESPACE to $TARGET_NAMESPACE..."
oc get secret "$SECRET_NAME" -n "$SOURCE_NAMESPACE" -o yaml > "${SECRET_NAME}.yaml"
sed -i "s/${SOURCE_NAMESPACE}/${TARGET_NAMESPACE}/" "${SECRET_NAME}.yaml"

if oc get secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" >/dev/null 2>&1; then
  oc delete secret "$SECRET_NAME" -n "$TARGET_NAMESPACE"
fi
oc apply -f "${SECRET_NAME}.yaml"
rm -f "${SECRET_NAME}.yaml"

echo ""
echo "==> Verifying copied cert in $TARGET_NAMESPACE..."
oc get secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"

if ! oc get secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -q "$NEW_HOST"; then
  echo "ERROR: copied cert in $TARGET_NAMESPACE does not contain the new SAN ($NEW_HOST)." >&2
  exit 1
fi

echo ""
echo "==> Done. Galera cert DNS updated, reissued, and copied to $TARGET_NAMESPACE."
