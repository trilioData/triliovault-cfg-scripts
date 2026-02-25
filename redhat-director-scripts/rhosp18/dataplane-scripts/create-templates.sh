#!/bin/bash

set -euo pipefail

# -------------------------------------------------------------
# Usage / Help
# -------------------------------------------------------------
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo ""
    echo "Usage:"
    echo "  ./create-templates.sh <BACKUP_TARGET_NAME> <BACKUP_TARGET_TYPE> [CERT_FILE]"
    echo ""
    echo "Arguments:"
    echo "  BACKUP_TARGET_NAME   Logical name (e.g. PROD_S3)"
    echo "  BACKUP_TARGET_TYPE   Template type (e.g. s3, nfs)"
    echo "  CERT_FILE            (Optional) Path to S3 CA certificate"
    echo ""
    echo "Examples:"
    echo "  ./create-templates.sh s3-prod-bt s3"
    echo "  ./create-templates.sh s3-prod-bt s3 mycert.pem"
    echo ""
    exit 1
fi



BACKUP_TARGET_NAME=$1
BACKUP_TARGET_TYPE=$2
CERT_FILE="${3:-}"

rm -rf ${BACKUP_TARGET_NAME}
mkdir ${BACKUP_TARGET_NAME}

cp trilio-add-backup-target-deployment.yaml trilio-add-backup-target-service.yaml ${BACKUP_TARGET_NAME}/
cp cm-trilio-backup-target-${BACKUP_TARGET_TYPE}.yaml ${BACKUP_TARGET_NAME}/cm-trilio-backup-target.yaml

cd ${BACKUP_TARGET_NAME}/
ORIGINAL_BACKUP_TARGET_NAME=$BACKUP_TARGET_NAME
BACKUP_TARGET_NAME=$(echo "$BACKUP_TARGET_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/_/-/g')
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-add-backup-target-deployment.yaml
sed -i "s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/g" trilio-add-backup-target-service.yaml
sed -i "/^  name: /s/<BACKUP_TARGET_NAME>/${BACKUP_TARGET_NAME}/" cm-trilio-backup-target.yaml
sed -i "s/<BACKUP_TARGET_NAME>/${ORIGINAL_BACKUP_TARGET_NAME}/g" cm-trilio-backup-target.yaml

if [[ -n "$CERT_FILE" ]]; then
    if [[ ! -f "$CERT_FILE" ]]; then
        echo "ERROR: Certificate file '$CERT_FILE' not found."
        exit 1
    fi

    echo "Injecting certificate into ConfigMap..."

    # Enable self-signed cert
    sed -i "s/s3_self_signed_cert: false/s3_self_signed_cert: true/" cm-trilio-backup-target.yaml

    # Inject cert content with correct indentation (8 spaces)
    awk '
    /s3_ssl_ca_cert:/ {
        print $0
        while ((getline line < "'"$CERT_FILE"'") > 0)
            print "        " line
        close("'"$CERT_FILE"'")
        next
    }
    { print }
    ' cm-trilio-backup-target.yaml > tmp && mv tmp cm-trilio-backup-target.yaml

else
    echo "No certificate provided. Removing CA block..."

    # Remove CA block line entirely
    sed -i '/s3_ssl_ca_cert:/d' cm-trilio-backup-target.yaml
fi

echo ""
echo "Templates created successfully in directory: $TARGET_DIR"
echo ""