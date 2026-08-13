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

# Build OpenStack credentials from the k8s secret — the pod has no admin-openrc.sh
ADMIN_SECRET="triliovault-keystone-admin"
OS_AUTH_URL=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_AUTH_URL}' | base64 --decode)
OS_PASSWORD=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_PASSWORD}' | base64 --decode)
OS_USERNAME=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_USERNAME}' | base64 --decode)
OS_PROJECT_NAME=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_PROJECT_NAME}' | base64 --decode)
OS_USER_DOMAIN_NAME=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_USER_DOMAIN_NAME}' | base64 --decode || echo "default")
OS_PROJECT_DOMAIN_NAME=$(kubectl get secret $ADMIN_SECRET -n $NAMESPACE -o jsonpath='{.data.OS_PROJECT_DOMAIN_NAME}' | base64 --decode || echo "default")

exec_in_wlm() {
    kubectl exec -n $NAMESPACE $WLM_POD -- bash -c "
      export OS_AUTH_URL=$(printf '%q' "$OS_AUTH_URL")
      export OS_PASSWORD=$(printf '%q' "$OS_PASSWORD")
      export OS_USERNAME=$(printf '%q' "$OS_USERNAME")
      export OS_PROJECT_NAME=$(printf '%q' "$OS_PROJECT_NAME")
      export OS_USER_DOMAIN_NAME=$(printf '%q' "$OS_USER_DOMAIN_NAME")
      export OS_PROJECT_DOMAIN_NAME=$(printf '%q' "$OS_PROJECT_DOMAIN_NAME")
      export OS_IDENTITY_API_VERSION=3
      export OS_REGION_NAME=RegionOne
      export OS_CACERT=/etc/ssl/certs/openstack-ca-bundle.pem
      export OS_INTERFACE=internal
      $*
    "
}

PASS=0
FAIL=0

for i in $(seq 0 $((COUNT - 1))); do
    BT_OBJ=$(echo "$TARGETS" | jq -c ".[$i]")
    MIG_SOURCE=$(echo "$BT_OBJ" | jq -r '.migration_source')
    # 6.1 workloadmgr JSON has no name field — fall back to sanitised Backend Endpoint or ID
    BT_NAME=$(echo "$BT_OBJ" | jq -r '.name // ."Name" // ."Backend Endpoint" // .ID' | tr '/.:' '-')
    BT_TYPE=$(echo "$BT_OBJ" | jq -r '.type // ."Type"')
    
    echo ""
    echo "----------------------------------------------------"
    echo "Processing target: $BT_NAME (Type: $BT_TYPE, Source: $MIG_SOURCE)"
    
    if [[ "$BT_TYPE" == *"nfs"* ]]; then
        # 6.1 JSON has no nfs_shares field — use Backend Endpoint directly
        NFS_EXPORT=$(echo "$BT_OBJ" | jq -r '.nfs_shares // ."Backend Endpoint"')
        
        # Check if target already exists natively in 6.2 (by Backend Endpoint or Name)
        EXISTS=$(exec_in_wlm "workloadmgr --insecure backup-target-list --format json" | jq -r ".[] | select(.Name == \"$BT_NAME\" or .\"Backend Endpoint\" == \"$NFS_EXPORT\") | .ID")
        
        if [ -n "$EXISTS" ]; then
            echo "✔ SKIP: NFS Target '$NFS_EXPORT' already exists in 6.2 WLM database (ID: $EXISTS)."
            echo "        No action required — this target was previously migrated or created natively."
            PASS=$((PASS + 1))
        else
            echo "Creating NFS Target '$BT_NAME' in 6.2 DB (export: $NFS_EXPORT)..."
            # 6.2 workloadmgr uses --btt-name, --filesystem-export, --default (flag, no value)
            exec_in_wlm "workloadmgr --insecure backup-target-create --btt-name '$BT_NAME' --type nfs --filesystem-export '$NFS_EXPORT' --default" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
        fi
    elif [[ "$BT_TYPE" == *"s3"* ]]; then
        # S3 Targets require Barbican Migration
        ACCESS_KEY=$(echo "$BT_OBJ" | jq -r '.s3_access_key // .access_key')
        SECRET_KEY=$(echo "$BT_OBJ" | jq -r '.s3_secret_key // .secret_key')
        BUCKET_RAW=$(echo "$BT_OBJ" | jq -r '.s3_bucket // .bucket // ."Backend Endpoint"')
        # Clean backend endpoint bucket name if from 6.1 (e.g. cephquincy.triliodata.demo/trilio-automation -> trilio-automation)
        BUCKET=$(echo "$BUCKET_RAW" | awk -F'/' '{print $NF}')
        # S3 endpoint URL — field name varies between 6.1 and 6.2 JSON schemas
        S3_ENDPOINT=$(echo "$BT_OBJ" | jq -r '.s3_endpoint // .endpoint_url // ."S3 Endpoint" // empty')
        # Check if target already exists natively in 6.2 (by Backend Endpoint or Name)
        EXISTS=$(exec_in_wlm "workloadmgr --insecure backup-target-list --format json" | jq -r ".[] | select(.Name == \"$BT_NAME\" or .\"Backend Endpoint\" == \"$BUCKET_RAW\") | .ID")
        
        if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" == "null" ]; then
            read -rsp "Enter S3 Secret Key for $BT_NAME: " SECRET_KEY
            echo ""
        fi
        
        echo "Pushing S3 credentials to OpenStack Barbican..."

        # trilio-dms-cli is a 6.2-only tool — skip S3 migration if pod is still on 6.1 images
        if ! exec_in_wlm "command -v trilio-dms-cli" >/dev/null 2>&1; then
            echo "SKIP: trilio-dms-cli not found in WLM pod. S3 migration requires 6.2 images."
            echo "      Run migrate_backup_targets_osh.sh again after upgrading to T4O 6.2."
            FAIL=$((FAIL + 1))
            continue
        fi

        # Build secret JSON via trilio-dms-cli inside WLM
        if [ -z "$S3_ENDPOINT" ] || [ "$S3_ENDPOINT" == "null" ]; then
            # AWS S3 (no endpoint URL provided)
            # filesystem-export is just the bucket name
            S3_FS_EXPORT="${BUCKET}"
            DMS_CMD="trilio-dms-cli secret-payload create --access-key '$ACCESS_KEY' --secret-key '$SECRET_KEY' --bucket '$BUCKET' --filesystem-export '$S3_FS_EXPORT' -o /tmp/secret.json"
        else
            # Non-AWS S3 (Ceph, etc.)
            # Extract domain from endpoint URL (e.g. https://s3.demo.com/ -> s3.demo.com)
            S3_DOMAIN=$(echo "$S3_ENDPOINT" | awk -F/ '{print $3}')
            # filesystem-export is <s3_domain>/<bucket>
            S3_FS_EXPORT="${S3_DOMAIN}/${BUCKET}"
            DMS_CMD="trilio-dms-cli secret-payload create --access-key '$ACCESS_KEY' --secret-key '$SECRET_KEY' --bucket '$BUCKET' --endpoint-url '$S3_ENDPOINT' --filesystem-export '$S3_FS_EXPORT' -o /tmp/secret.json"
        fi
        exec_in_wlm "$DMS_CMD"
        
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
            echo "Creating S3 Target '$BT_NAME' in 6.2 DB..."
            exec_in_wlm "workloadmgr --insecure backup-target-create --btt-name '$BT_NAME' --type amazon_s3 --secret-ref '$FINAL_HREF' --default" && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
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
