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
    
    # We must ensure the API is responding
    WLM_BT_JSON=$(kubectl exec -n $ACTIVE_NAMESPACE $WLM_POD -- bash -c "source /etc/triliovault-wlm/admin-openrc.sh && workloadmgr --insecure backup-target-list --format json" 2>/dev/null || echo "[]")
    
    BT_COUNT=$(echo "$WLM_BT_JSON" | jq 'length')
    if [ "$BT_COUNT" -gt 0 ]; then
        echo "Found $BT_COUNT backup target(s) natively in WLM (6.1 architecture)."
        
        FINAL_JSON="[]"
        for i in $(seq 0 $((BT_COUNT - 1))); do
            BT_OBJ=$(echo "$WLM_BT_JSON" | jq -c ".[$i]")
            BT_TYPE=$(echo "$BT_OBJ" | jq -r '."Type" // .type // "s3"')
            
            if [[ "$BT_TYPE" == *"s3"* ]]; then
                BT_NAME=$(echo "$BT_OBJ" | jq -r '."Name"')
                SECRET_NAME="secret-key-${BT_NAME// /-}"
                
                # Fetch secret
                ACCESS_KEY=$(kubectl get secret -n $ACTIVE_NAMESPACE $SECRET_NAME -o jsonpath="{.data.access_key}" 2>/dev/null | base64 --decode || true)
                SECRET_KEY=$(kubectl get secret -n $ACTIVE_NAMESPACE $SECRET_NAME -o jsonpath="{.data.secret_key}" 2>/dev/null | base64 --decode || true)
                
                BT_OBJ=$(echo "$BT_OBJ" | jq ". + {\"access_key\": \"$ACCESS_KEY\", \"secret_key\": \"$SECRET_KEY\", \"migration_source\": \"6.1\"}")
            else
                BT_OBJ=$(echo "$BT_OBJ" | jq ". + {\"migration_source\": \"6.1\"}")
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
