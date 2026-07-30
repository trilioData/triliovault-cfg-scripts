#!/usr/bin/env bash
# 01_create_backup_targets.sh
# Creates T4O backup targets on Sunbeam Canonical OpenStack:
#   - BT1_S3: Ceph RGW with self-signed SSL cert (default target)
#   - BT2_S3: Wasabi S3
#   - BT_NFS: NFS target
#
# All endpoint URLs, bucket names, credentials, and NFS paths are loaded from:
#   <workspace-root>/env/backup_targets.yaml
#
# Override the env directory with: export TRILIO_ENV_DIR=/path/to/env
#
# Adapted from kolla-ansible/ansible/create_backup_target_62.yml
# Sunbeam difference: no Barbican — a minimal K8s secret-server pod serves
# the DMS secret payload JSON over HTTP on a stable ClusterIP.
#
# Usage:
#   bash 01_create_backup_targets.sh
#
# Verify:
#   kubectl exec -n openstack trilio-wlm-k8s-0 -c trilio-wlm -- \
#     env OS_AUTH_URL=... workloadmgr backup-target-list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./env.sh
source "$SCRIPT_DIR/env.sh"

# ---------------------------------------------------------------------------
# Load backup target config from env/backup_targets.yaml
# ---------------------------------------------------------------------------

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BACKUP_TARGETS_FILE="${TRILIO_ENV_DIR:-${WORKSPACE_ROOT}/env}/backup_targets.yaml"

if [[ ! -f "$BACKUP_TARGETS_FILE" ]]; then
  echo "ERROR: $BACKUP_TARGETS_FILE not found." >&2
  echo "  Set TRILIO_ENV_DIR to point to your local env directory." >&2
  exit 1
fi

echo "Loading backup target config from: $BACKUP_TARGETS_FILE"

_ENV_TMPFILE=$(mktemp /tmp/trilio-bt-env-XXXXXX.sh)
trap "rm -f $_ENV_TMPFILE" EXIT

python3 - "$BACKUP_TARGETS_FILE" > "$_ENV_TMPFILE" << 'PYEOF'
import sys
try:
    import yaml
except ImportError:
    sys.exit('ERROR: python3-yaml not installed. Run: pip3 install pyyaml')

with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f)

targets = {t['backup_target_name']: t for t in cfg.get('triliovault_backup_targets', [])}

bt1 = targets.get('BT1_S3', {})
bt2 = targets.get('BT2_S3', {})
nfs = targets.get('BT_NFS', {})

# Write BT1 CA cert to a temp file on the local machine
ca_cert = bt1.get('s3_ssl_ca_cert', '').strip()
ca_file = '/tmp/trilio-bt1-ca.pem'
if ca_cert:
    with open(ca_file, 'w') as fh:
        fh.write(ca_cert + '\n')

def sh(name, val):
    val = str(val).replace("'", "'\\''")
    print(f"{name}='{val}'")

sh('BT1_NAME',         bt1.get('backup_target_name', 'BT1_S3'))
sh('BT1_ENDPOINT',     bt1.get('s3_endpoint_url', ''))
sh('BT1_BUCKET',       bt1.get('s3_bucket', ''))
sh('BT1_REGION',       bt1.get('s3_region_name', 'us-east-1'))
sh('BT1_AUTH_VERSION', bt1.get('s3_auth_version', 'DEFAULT'))
sh('BT1_SIG_VERSION',  bt1.get('s3_signature_version', 'default'))
sh('BT1_SSL',          'true' if bt1.get('s3_ssl_enabled', True) else 'false')
sh('BT1_SSL_VERIFY',   'true' if bt1.get('s3_ssl_verify', True) else 'false')
sh('BT1_CA_CERT_FILE', ca_file if ca_cert else '')
sh('BT1_ACCESS_KEY',   bt1.get('s3_access_key', ''))
sh('BT1_SECRET_KEY',   bt1.get('s3_secret_key', ''))
sh('BT1_DEFAULT',      'true' if bt1.get('is_default', False) else 'false')

sh('BT2_NAME',         bt2.get('backup_target_name', 'BT2_S3'))
sh('BT2_ENDPOINT',     bt2.get('s3_endpoint_url', ''))
sh('BT2_BUCKET',       bt2.get('s3_bucket', ''))
sh('BT2_REGION',       bt2.get('s3_region_name', 'us-east-1'))
sh('BT2_AUTH_VERSION', bt2.get('s3_auth_version', 'DEFAULT'))
sh('BT2_SIG_VERSION',  bt2.get('s3_signature_version', 'default'))
sh('BT2_SSL',          'true' if bt2.get('s3_ssl_enabled', True) else 'false')
sh('BT2_ACCESS_KEY',   bt2.get('s3_access_key', ''))
sh('BT2_SECRET_KEY',   bt2.get('s3_secret_key', ''))

sh('NFS_TARGET_NAME',    nfs.get('backup_target_name', 'BT_NFS'))
sh('NFS_SERVER_EXPORT',  nfs.get('nfs_server_export', ''))
sh('NFS_MOUNT_OPTS',     nfs.get('nfs_mount_opts', ''))
PYEOF

# shellcheck source=/dev/null
source "$_ENV_TMPFILE"

# Validate mandatory fields were loaded
for var in BT1_ENDPOINT BT1_BUCKET BT1_ACCESS_KEY BT1_SECRET_KEY \
           BT2_ENDPOINT BT2_BUCKET BT2_ACCESS_KEY BT2_SECRET_KEY \
           NFS_SERVER_EXPORT; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is empty after loading $BACKUP_TARGETS_FILE" >&2
    exit 1
  fi
done

# Derive filesystem_export from endpoint hostname + bucket (strip https://)
BT1_FS_EXPORT="${BT1_ENDPOINT#https://}/${BT1_BUCKET}"
BT2_FS_EXPORT="${BT2_ENDPOINT#https://}/${BT2_BUCKET}"

echo "OS_AUTH_URL: $OS_AUTH_URL"
echo "OS_USERNAME: $OS_USERNAME / project: $OS_PROJECT_NAME"
echo "BT1_S3:  $BT1_ENDPOINT  bucket=$BT1_BUCKET  default=$BT1_DEFAULT"
echo "BT2_S3:  $BT2_ENDPOINT  bucket=$BT2_BUCKET"
echo "BT_NFS:  $NFS_SERVER_EXPORT"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

wlm_exec() {
  kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
    env OS_AUTH_URL="$OS_AUTH_URL" \
        OS_USERNAME="$OS_USERNAME" \
        OS_PASSWORD="$OS_PASSWORD" \
        OS_PROJECT_NAME="$OS_PROJECT_NAME" \
        OS_USER_DOMAIN_NAME="$OS_USER_DOMAIN_NAME" \
        OS_PROJECT_DOMAIN_NAME="$OS_PROJECT_DOMAIN_NAME" \
        OS_IDENTITY_API_VERSION="$OS_IDENTITY_API_VERSION" \
    "$@"
}

# ---------------------------------------------------------------------------
# Step 1: Generate S3 secret payloads via trilio-dms-cli inside the WLM pod
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: Generating S3 secret payloads ==="

if [[ -n "$BT1_CA_CERT_FILE" && -f "$BT1_CA_CERT_FILE" ]]; then
  echo "  Copying BT1 CA cert to pod..."
  kubectl cp "$BT1_CA_CERT_FILE" \
    "$K8S_NAMESPACE/$WLM_POD:/tmp/bt1-ca.pem" -c "$WLM_CONTAINER"
  BT1_SSL_CERT_ARG="--ssl-cert /tmp/bt1-ca.pem"
else
  BT1_SSL_CERT_ARG=""
fi

echo "  Generating BT1_S3 payload ($BT1_NAME, CA cert)..."
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  env VAULT_S3_ACCESS_KEY_ID="$BT1_ACCESS_KEY" \
      VAULT_S3_SECRET_ACCESS_KEY="$BT1_SECRET_KEY" \
  trilio-dms-cli secret-payload create \
    --bucket            "$BT1_BUCKET" \
    --endpoint-url      "$BT1_ENDPOINT" \
    --filesystem-export "$BT1_FS_EXPORT" \
    --region            "$BT1_REGION" \
    --auth-version      "$BT1_AUTH_VERSION" \
    --signature-version "$BT1_SIG_VERSION" \
    --ssl \
    --ssl-verify \
    $BT1_SSL_CERT_ARG \
    -o /tmp/bt1_s3_secret.json

[[ -n "$BT1_CA_CERT_FILE" ]] && \
  kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- rm -f /tmp/bt1-ca.pem

echo "  Generating BT2_S3 payload ($BT2_NAME)..."
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  env VAULT_S3_ACCESS_KEY_ID="$BT2_ACCESS_KEY" \
      VAULT_S3_SECRET_ACCESS_KEY="$BT2_SECRET_KEY" \
  trilio-dms-cli secret-payload create \
    --bucket            "$BT2_BUCKET" \
    --endpoint-url      "$BT2_ENDPOINT" \
    --filesystem-export "$BT2_FS_EXPORT" \
    --region            "$BT2_REGION" \
    --auth-version      "$BT2_AUTH_VERSION" \
    --signature-version "$BT2_SIG_VERSION" \
    --ssl \
    --ssl-verify \
    -o /tmp/bt2_s3_secret.json

# Copy payloads out of pod
BT1_PAYLOAD=$(kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- cat /tmp/bt1_s3_secret.json)
BT2_PAYLOAD=$(kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- cat /tmp/bt2_s3_secret.json)
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  rm -f /tmp/bt1_s3_secret.json /tmp/bt2_s3_secret.json

echo "  Payloads generated."

# ---------------------------------------------------------------------------
# Step 2: Deploy minimal secret-server in Kubernetes
#
# Barbican is not deployed in Sunbeam by default. The secret-server is a
# lightweight Python HTTP pod that serves the DMS secret payloads over HTTP
# on a ClusterIP. MicroK8s ClusterIPs are reachable from the host machine
# (DataMover compute side) via the bridge network.
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Deploying secret-server (Barbican replacement) ==="

kubectl create configmap trilio-secret-payloads \
  -n "$K8S_NAMESPACE" \
  --from-literal="BT1_S3.json=$BT1_PAYLOAD" \
  --from-literal="BT2_S3.json=$BT2_PAYLOAD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SECRET_SERVER_SVC}
  namespace: ${K8S_NAMESPACE}
spec:
  selector:
    app: ${SECRET_SERVER_SVC}
  ports:
  - port: ${SECRET_SERVER_PORT}
    targetPort: ${SECRET_SERVER_PORT}
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SECRET_SERVER_SVC}
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${SECRET_SERVER_SVC}
  template:
    metadata:
      labels:
        app: ${SECRET_SERVER_SVC}
    spec:
      containers:
      - name: server
        image: python:3.11-slim
        command: ["python3", "-c"]
        args:
        - |
          import os, sys
          from http.server import HTTPServer, BaseHTTPRequestHandler
          class H(BaseHTTPRequestHandler):
              def do_GET(self):
                  name = self.path.lstrip('/')
                  path = f'/secrets/{name}'
                  if os.path.exists(path):
                      data = open(path, 'rb').read()
                      self.send_response(200)
                      self.send_header('Content-Type', 'application/octet-stream')
                      self.send_header('Content-Length', str(len(data)))
                      self.end_headers()
                      self.wfile.write(data)
                  else:
                      self.send_response(404)
                      self.end_headers()
              def log_message(self, fmt, *args):
                  sys.stderr.write('%s %s\n' % (self.address_string(), fmt % args))
          HTTPServer(('', ${SECRET_SERVER_PORT}), H).serve_forever()
        ports:
        - containerPort: ${SECRET_SERVER_PORT}
        volumeMounts:
        - name: secrets
          mountPath: /secrets
      volumes:
      - name: secrets
        configMap:
          name: trilio-secret-payloads
EOF

echo "  Waiting for secret-server pod to be ready..."
kubectl rollout status deployment/"$SECRET_SERVER_SVC" -n "$K8S_NAMESPACE" --timeout=120s

SECRET_SERVER_IP=$(kubectl get svc "$SECRET_SERVER_SVC" -n "$K8S_NAMESPACE" -o jsonpath='{.spec.clusterIP}')
echo "  Secret-server ClusterIP: $SECRET_SERVER_IP:$SECRET_SERVER_PORT"

BT1_SECRET_REF="http://${SECRET_SERVER_IP}:${SECRET_SERVER_PORT}/BT1_S3.json"
BT2_SECRET_REF="http://${SECRET_SERVER_IP}:${SECRET_SERVER_PORT}/BT2_S3.json"

echo "  Verifying secret-server is reachable from WLM pod..."
wlm_exec curl -sf "$BT1_SECRET_REF" -o /dev/null && echo "  BT1_S3.json: reachable" \
  || { echo "ERROR: secret-server not reachable from WLM pod at $BT1_SECRET_REF" >&2; exit 1; }
wlm_exec curl -sf "$BT2_SECRET_REF" -o /dev/null && echo "  BT2_S3.json: reachable"

# ---------------------------------------------------------------------------
# Step 3: Create S3 backup targets
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Creating S3 backup targets ==="

DEFAULT_FLAG=""
[[ "$BT1_DEFAULT" == "true" ]] && DEFAULT_FLAG="--default"

echo "  Creating $BT1_NAME (Ceph)..."
wlm_exec workloadmgr backup-target-create \
  --btt-name        "$BT1_NAME" \
  --type s3 \
  --s3-endpoint-url "$BT1_ENDPOINT" \
  --s3-bucket       "$BT1_BUCKET" \
  --secret-ref      "$BT1_SECRET_REF" \
  $DEFAULT_FLAG \
  -f json

echo ""
echo "  Creating $BT2_NAME (Wasabi)..."
wlm_exec workloadmgr backup-target-create \
  --btt-name        "$BT2_NAME" \
  --type s3 \
  --s3-endpoint-url "$BT2_ENDPOINT" \
  --s3-bucket       "$BT2_BUCKET" \
  --secret-ref      "$BT2_SECRET_REF" \
  -f json

# ---------------------------------------------------------------------------
# Step 4: Create NFS backup target
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Creating NFS backup target ==="
echo "  NFS export: $NFS_SERVER_EXPORT"

wlm_exec workloadmgr backup-target-create \
  --btt-name        "$NFS_TARGET_NAME" \
  --type nfs \
  --filesystem-export "$NFS_SERVER_EXPORT" \
  --nfs-mount-opts    "$NFS_MOUNT_OPTS" \
  -f json

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo ""
echo "=== Backup target list ==="
wlm_exec workloadmgr backup-target-list
