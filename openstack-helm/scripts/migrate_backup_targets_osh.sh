#!/bin/bash
# migrate_backup_targets_osh.sh
# Run this AFTER upgrading to T4O 6.2 in OpenStack-Helm

set -e

NAMESPACE="trilio-openstack"
INPUT_FILE="existing_backup_targets.json"

echo "=========================================================="
echo " Migrating Backup Targets to T4O 6.2"
echo "=========================================================="

if [ ! -f "$INPUT_FILE" ]; then
    echo "No $INPUT_FILE found. This is likely a fresh install or collect was not run."
    echo "Exiting gracefully."
    exit 0
fi

TARGETS=$(cat "$INPUT_FILE")
COUNT=$(echo "$TARGETS" | jq 'length')

if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
    echo "No targets to migrate (file is empty). Exiting gracefully."
    exit 0
fi

echo "Waiting for WLM API pod to be ready..."
kubectl wait pods -n $NAMESPACE -l component=wlm-api --for=condition=Ready --timeout=300s

WLM_POD=$(kubectl get pods -n $NAMESPACE -l component=wlm-api -o jsonpath="{.items[0].metadata.name}")

exec_in_wlm() {
    kubectl exec -n $NAMESPACE $WLM_POD -- bash -c "source /etc/triliovault-wlm/admin-openrc.sh && export OS_ENDPOINT_TYPE=internal && $*"
}

# Ensure tools are available inside pod
if ! exec_in_wlm "command -v trilio-dms-cli" >/dev/null 2>&1; then
    echo "ERROR: trilio-dms-cli not found in $WLM_POD. Migration cannot proceed."
    exit 1
fi

PASS=0
FAIL=0

for i in $(seq 0 $((COUNT - 1))); do
    BT_OBJ=$(echo "$TARGETS" | jq -c ".[$i]")
    MIG_SOURCE=$(echo "$BT_OBJ" | jq -r '.migration_source')
    BT_NAME=$(echo "$BT_OBJ" | jq -r '.name // ."Name"')
    BT_TYPE=$(echo "$BT_OBJ" | jq -r '.type // ."Type"')
    
    echo ""
    echo "----------------------------------------------------"
    echo "Processing target: $BT_NAME (Type: $BT_TYPE, Source: $MIG_SOURCE)"
    
    # Check if target already exists natively in 6.2 (by name)
    EXISTS=$(exec_in_wlm "workloadmgr --insecure backup-target-list --format json" | jq -r ".[] | select(.Name == \"$BT_NAME\") | .ID")
    
    if [[ "$BT_TYPE" == *"nfs"* ]]; then
        if [ -n "$EXISTS" ]; then
            echo "NFS Target $BT_NAME already exists in WLM database. No migration needed."
            PASS=$((PASS + 1))
        else
            NFS_SHARES=$(echo "$BT_OBJ" | jq -r '.nfs_shares')
            NFS_OPTS=$(echo "$BT_OBJ" | jq -r '.nfs_options')
            echo "Creating 5.2 NFS Target in 6.2 DB..."
            exec_in_wlm "workloadmgr --insecure backup-target-create --name '$BT_NAME' --type nfs --nfs-shares '$NFS_SHARES' --nfs-options '$NFS_OPTS' --is-default true" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
        fi
    elif [[ "$BT_TYPE" == *"s3"* ]]; then
        # S3 Targets require Barbican Migration
        ACCESS_KEY=$(echo "$BT_OBJ" | jq -r '.s3_access_key // .access_key')
        SECRET_KEY=$(echo "$BT_OBJ" | jq -r '.s3_secret_key // .secret_key')
        BUCKET=$(echo "$BT_OBJ" | jq -r '.s3_bucket // .bucket // ."Backend Endpoint"')
        
        # Clean backend endpoint bucket name if from 6.1
        BUCKET=$(echo "$BUCKET" | awk -F'/' '{print $NF}')
        
        if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" == "null" ]; then
            read -rsp "Enter S3 Secret Key for $BT_NAME: " SECRET_KEY
            echo ""
        fi
        
        echo "Pushing S3 credentials to OpenStack Barbican..."
        
        # Build secret JSON via trilio-dms-cli inside WLM
        exec_in_wlm "trilio-dms-cli secret-payload create --access-key '$ACCESS_KEY' --secret-key '$SECRET_KEY' --bucket '$BUCKET' -o /tmp/secret.json"
        
        # Push to barbican
        BARBICAN_JSON=$(exec_in_wlm "openstack secret store --name 'secret-key-$BT_NAME' --payload \"\$(cat /tmp/secret.json)\" -f json")
        SECRET_HREF=$(echo "$BARBICAN_JSON" | jq -r '. | if type=="array" then .[0] else . end | .secret_href // ."Secret href" // .href')
        
        if [ -z "$SECRET_HREF" ] || [ "$SECRET_HREF" == "null" ]; then
            echo "Failed to get Barbican secret href."
            FAIL=$((FAIL + 1))
            continue
        fi

        # Validate HREF using keystone public endpoint
        SECRET_UUID=$(echo "$SECRET_HREF" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        BARB_PUB=$(exec_in_wlm "OS_INTERFACE=public openstack endpoint list --service key-manager --interface public -f json | jq -r '.[0].URL'")
        if [[ "$BARB_PUB" == */v1 ]]; then BARB_PUB=${BARB_PUB::-3}; fi
        
        FINAL_HREF="$BARB_PUB/v1/secrets/$SECRET_UUID"
        echo "Successfully stored in Barbican: $FINAL_HREF"
        
        if [ -n "$EXISTS" ]; then
            echo "Modifying existing 6.1 Target with new Barbican Secret Ref..."
            exec_in_wlm "workloadmgr --insecure backup-target-modify --secret-ref '$FINAL_HREF' $EXISTS" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
        else
            echo "Creating 5.2 S3 Target in 6.2 DB..."
            exec_in_wlm "workloadmgr --insecure backup-target-create --name '$BT_NAME' --type amazon_s3 --secret-ref '$FINAL_HREF' --is-default true" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
        fi
        
        # Cleanup
        exec_in_wlm "rm -f /tmp/secret.json"
    fi
done

echo ""
echo "=========================================================="
echo " Migration Summary"
echo "=========================================================="
echo "Succeeded: $PASS"
echo "Failed:    $FAIL"
echo "=========================================================="

exec_in_wlm "workloadmgr --insecure backup-target-list"
