#!/bin/bash
# collect_backup_targets_osh.sh
# Run this BEFORE upgrading to T4O 6.2 in OpenStack-Helm

set -e

NAMESPACE="trilio-openstack"
RELEASE_NAME="trilio-openstack"
OUTPUT_FILE="existing_backup_targets.json"

echo "=========================================================="
echo " Collecting Existing Backup Targets (T4O 5.2 / 6.1)"
echo "=========================================================="

# 1. Fresh Install / Release Check
if helm status $RELEASE_NAME -n $NAMESPACE >/dev/null 2>&1; then
    ACTIVE_NAMESPACE=$NAMESPACE
    ACTIVE_RELEASE=$RELEASE_NAME
elif helm status triliovault -n triliovault >/dev/null 2>&1; then
    ACTIVE_NAMESPACE="triliovault"
    ACTIVE_RELEASE="triliovault"
else
    echo "No existing Helm release found in 'trilio-openstack' or 'triliovault' namespaces."
    echo "This appears to be a fresh installation. No backup targets to collect."
    echo "[]" > $OUTPUT_FILE
    exit 0
fi

# Initialize an empty JSON array
echo "[]" > $OUTPUT_FILE

# 2. Try 6.1 Mode (via WLM Pod API)
WLM_POD=$(kubectl get pods -n $ACTIVE_NAMESPACE -l component=wlm-api -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
if [ -n "$WLM_POD" ]; then
    echo "Querying existing WLM pod: $WLM_POD for 6.1 backup targets..."

    # Extract admin credentials from the keystone-admin secret (service user gets HTTP 401)
    ADMIN_SECRET="triliovault-keystone-admin"
    OS_AUTH_URL=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_AUTH_URL}' 2>/dev/null | base64 --decode || true)
    OS_PASSWORD=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_PASSWORD}' 2>/dev/null | base64 --decode || true)
    OS_USERNAME=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_USERNAME}' 2>/dev/null | base64 --decode || true)
    OS_PROJECT_NAME=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_PROJECT_NAME}' 2>/dev/null | base64 --decode || true)
    OS_USER_DOMAIN_NAME=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_USER_DOMAIN_NAME}' 2>/dev/null | base64 --decode || echo "default")
    OS_PROJECT_DOMAIN_NAME=$(kubectl get secret $ADMIN_SECRET -n $ACTIVE_NAMESPACE -o jsonpath='{.data.OS_PROJECT_DOMAIN_NAME}' 2>/dev/null | base64 --decode || echo "default")

    WLM_ENDPOINT="http://triliovault-wlm-api.${ACTIVE_NAMESPACE}.svc.cluster.local:8780"
    # Use printf %q to safely escape credentials — prevents special chars in passwords breaking the shell
    Q_PASSWORD=$(printf '%q' "$OS_PASSWORD")
    Q_AUTH_URL=$(printf '%q' "$OS_AUTH_URL")
    Q_USERNAME=$(printf '%q' "$OS_USERNAME")
    Q_PROJECT=$(printf '%q' "$OS_PROJECT_NAME")
    Q_UDOM=$(printf '%q' "$OS_USER_DOMAIN_NAME")
    Q_PDOM=$(printf '%q' "$OS_PROJECT_DOMAIN_NAME")

    WLM_BT_JSON=$(kubectl exec -n "$ACTIVE_NAMESPACE" "$WLM_POD" -- bash -c "
      export OS_AUTH_URL=$Q_AUTH_URL
      export OS_PASSWORD=$Q_PASSWORD
      export OS_USERNAME=$Q_USERNAME
      export OS_PROJECT_NAME=$Q_PROJECT
      export OS_USER_DOMAIN_NAME=$Q_UDOM
      export OS_PROJECT_DOMAIN_NAME=$Q_PDOM
      export OS_IDENTITY_API_VERSION=3
      export OS_REGION_NAME=RegionOne
      export OS_CACERT=/etc/ssl/certs/openstack-ca-bundle.pem
      export OS_INTERFACE=internal
      workloadmgr --insecure backup-target-list --format json 2>/dev/null
    " 2>/dev/null || echo "[]")

    # Strip any preamble lines kubectl/Python may inject before the JSON array
    WLM_BT_JSON=$(echo "$WLM_BT_JSON" | awk '/^\[/{found=1} found{print}')
    [ -z "$WLM_BT_JSON" ] && WLM_BT_JSON="[]"

    BT_COUNT=$(echo "$WLM_BT_JSON" | jq 'length')
    if [ "$BT_COUNT" -gt 0 ]; then
        echo "Found $BT_COUNT backup target(s) natively in WLM."
        
        FINAL_JSON="[]"
        for i in $(seq 0 $((BT_COUNT - 1))); do
            BT_OBJ=$(echo "$WLM_BT_JSON" | jq -c ".[$i]")
            BT_TYPE=$(echo "$BT_OBJ" | jq -r '."Type" // .type // "s3"')
            
            if [[ "$BT_TYPE" == *"s3"* ]]; then
                BT_ENDPOINT=$(echo "$BT_OBJ" | jq -r '."Backend Endpoint" // ""')
                BT_ID=$(echo "$BT_OBJ" | jq -r '.ID // ""')
                ACCESS_KEY=""
                SECRET_KEY=""
                ENDPOINT_URL=""

                # Scan all 6.1 object-store secrets and match by Backend Endpoint
                while IFS= read -r SECRET_NAME; do
                    [ -z "$SECRET_NAME" ] && continue
                    SLUG="${SECRET_NAME#trilio-object-store-etc-single-bt-}"
                    CONF_KEY="trilio-object-store-${SLUG}.conf"

                    # Use jq to safely decode — avoids jsonpath single-quote interpolation issues
                    CONF_DATA=$(kubectl get secret -n $ACTIVE_NAMESPACE "$SECRET_NAME" \
                        -o json 2>/dev/null \
                        | jq -r --arg k "$CONF_KEY" '.data[$k] // "" | @base64d')
                    [ -z "$CONF_DATA" ] && continue

                    # vault_storage_nfs_export = domain/bucket or bucket — matches WLM Backend Endpoint directly
                    CONF_NFS_EXPORT=$(echo "$CONF_DATA" | awk -F' = ' '/^vault_storage_nfs_export/{print $2}' | tr -d '\r')
                    CONF_BUCKET=$(echo "$CONF_DATA" | awk -F' = ' '/^vault_s3_bucket/{print $2}' | tr -d '\r')

                    if [[ "$BT_ENDPOINT" == "$CONF_NFS_EXPORT" ]] || [[ "$BT_ENDPOINT" == "$CONF_BUCKET" ]]; then
                        ACCESS_KEY=$(echo "$CONF_DATA" | awk -F' = ' '/^vault_s3_access_key_id/{print $2}' | tr -d '\r')
                        SECRET_KEY=$(echo "$CONF_DATA" | awk -F' = ' '/^vault_s3_secret_access_key/{print $2}' | tr -d '\r')
                        ENDPOINT_URL=$(echo "$CONF_DATA" | awk -F' = ' '/^vault_s3_endpoint_url/{print $2}' | tr -d '\r ')
                        echo "  Matched 6.1 credentials via secret $SECRET_NAME for target $BT_ID"
                        break
                    fi
                done < <(kubectl get secrets -n $ACTIVE_NAMESPACE \
                    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
                    | tr ' ' '\n' | grep '^trilio-object-store-etc-single-bt-')

                BT_OBJ=$(echo "$BT_OBJ" | jq \
                    --arg ak "$ACCESS_KEY" \
                    --arg sk "$SECRET_KEY" \
                    --arg ep "$ENDPOINT_URL" \
                    '. + {"access_key": $ak, "secret_key": $sk, "endpoint_url": $ep, "migration_source": "6.1"}')
            else
                BT_OBJ=$(echo "$BT_OBJ" | jq '. + {"migration_source": "6.1"}')
            fi
            
            FINAL_JSON=$(echo "$FINAL_JSON" | jq ". + [$BT_OBJ]")
        done
        
        echo "$FINAL_JSON" > $OUTPUT_FILE
        echo "Backup targets safely written to $OUTPUT_FILE"
        exit 0
    fi
fi

# 3. 5.2 Mode (via Helm Values)
echo "No native WLM backup targets found. Checking Helm values for 5.2 static configuration..."
VALUES_JSON=$(helm get values $ACTIVE_RELEASE -n $ACTIVE_NAMESPACE -o json)

BT_TYPE=$(echo "$VALUES_JSON" | jq -r '.conf.triliovault.backup_target_type // empty')

if [ -z "$BT_TYPE" ] || [ "$BT_TYPE" == "null" ]; then
    echo "No backup_target_type found in Helm values. This might be a fresh install or already purged."
    exit 0
fi

echo "Found 5.2 static backup target of type: $BT_TYPE"

if [ "$BT_TYPE" == "nfs" ]; then
    NFS_CONF=$(echo "$VALUES_JSON" | jq -c '.conf.triliovault.nfs')
    NFS_PATH=$(echo "$NFS_CONF" | jq -r '.nfs_shares[0].path // empty')
    NFS_IP=$(echo "$NFS_CONF" | jq -r '.nfs_shares[0].ip // empty')
    NFS_OPTIONS=$(echo "$NFS_CONF" | jq -r '.nfs_options // empty')
    
    cat <<EOF > $OUTPUT_FILE
[
  {
    "migration_source": "5.2",
    "name": "default-nfs-target",
    "type": "nfs",
    "nfs_shares": "$NFS_IP:$NFS_PATH",
    "nfs_options": "$NFS_OPTIONS"
  }
]
EOF
elif [ "$BT_TYPE" == "s3" ]; then
    S3_CONF=$(echo "$VALUES_JSON" | jq -c '.conf.triliovault.s3')
    cat <<EOF > $OUTPUT_FILE
[
  {
    "migration_source": "5.2",
    "name": "default-s3-target",
    "type": "amazon_s3",
    "s3_access_key": $(echo "$S3_CONF" | jq '.access_key'),
    "s3_secret_key": $(echo "$S3_CONF" | jq '.secret_key'),
    "s3_bucket": $(echo "$S3_CONF" | jq '.bucket'),
    "s3_region": $(echo "$S3_CONF" | jq '.region_name'),
    "s3_endpoint": $(echo "$S3_CONF" | jq '.endpoint_url'),
    "ssl_enabled": $(echo "$S3_CONF" | jq '.ssl_enabled')
  }
]
EOF
fi

echo "Backup targets safely written to $OUTPUT_FILE"
echo "Done."
