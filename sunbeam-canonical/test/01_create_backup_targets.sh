#!/usr/bin/env bash
# 01_create_backup_targets.sh
# Creates T4O backup targets on Sunbeam Canonical OpenStack:
#   - BT1_S3: Ceph RGW with self-signed SSL cert (default target)
#   - BT2_S3: Wasabi S3
#   - BT_NFS:  NFS target
#
# Adapted from kolla-ansible/ansible/create_backup_target_62.yml
# Sunbeam difference: no Barbican — a minimal K8s secret-server pod serves
# the DMS secret payload JSON over HTTP on a stable ClusterIP, accessible to
# both the WLM pod and the DataMover on the compute host.
#
# Usage:
#   export BT1_S3_ACCESS_KEY=<ceph-key>  BT1_S3_SECRET_KEY=<ceph-secret>
#   export BT2_S3_ACCESS_KEY=<wasabi-key> BT2_S3_SECRET_KEY=<wasabi-secret>
#   export NFS_SERVER_EXPORT=<ip>:<path>   # optional, overrides env.sh default
#   bash 01_create_backup_targets.sh
#
# Verify:
#   kubectl exec -n openstack trilio-wlm-k8s-0 -c trilio-wlm -- \
#     env OS_AUTH_URL=... workloadmgr backup-target-list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./env.sh
source "$SCRIPT_DIR/env.sh"

# Validate S3 credentials are provided
for var in BT1_S3_ACCESS_KEY BT1_S3_SECRET_KEY BT2_S3_ACCESS_KEY BT2_S3_SECRET_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set. Export it before running this script." >&2
    exit 1
  fi
done

echo "OS_AUTH_URL: $OS_AUTH_URL"
echo "OS_USERNAME: $OS_USERNAME / project: $OS_PROJECT_NAME"

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
# CA cert for BT1_S3 (Ceph with self-signed cert)
# ---------------------------------------------------------------------------

BT1_CA_CERT="-----BEGIN CERTIFICATE-----
MIIF9TCCA92gAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwgZAxCzAJBgNVBAYTAklO
MQswCQYDVQQIDAJNSDENMAsGA1UEBwwEUFVORTEPMA0GA1UECgwGVFJJTElPMQsw
CQYDVQQLDAJJVDEaMBgGA1UEAwwRKi50cmlsaW9kYXRhLmRlbW8xKzApBgkqhkiG
9w0BCQEWHHByYXNoYW50LnNha2hhcmthckB0cmlsaW8uaW8wHhcNMTkwNjEzMDkx
NDE5WhcNMjkwNjEwMDkxNDE5WjCBgTELMAkGA1UEBhMCSU4xCzAJBgNVBAgMAk1I
MQ8wDQYDVQQKDAZUUklMSU8xCzAJBgNVBAsMAklUMRowGAYDVQQDDBEqLnRyaWxp
b2RhdGEuZGVtbzErMCkGCSqGSIb3DQEJARYccHJhc2hhbnQuc2FraGFya2FyQHRy
aWxpby5pbzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK0NE9RKKcaI
Ky/2vI5AaKXITNU/UvSI9bQtwpNM2Pg0k3k0osM3FajJpjpNhQBh4ulheYWRdTPU
EtMwOyALXOew9dq60k48fBRhnowal6Aan/afuJjaNEhRleiL0H9j0/io/fAnDl5N
B7oYC/W8LGoqUjmoUe5fZIIADNOHbuD7K2YsR9Z3hQogDTp5u4azrla9/zQZAL4J
s2xbDdjpz5fhdCs14nVH/EJAA1Yu9CI41L5C2VDrT2ieOCkt/FrN+FN1Edjm1KHZ
qm70TCcQLEljrioKBMRnjNsnOfw+xuqr4CD0UBfGlpEQPt3+gagEIkJkzPQZppsz
60MMX0cidVhLToz2dpVXwuqTJyvXpN0uMtPo5QoAtH/kVQwdNO48V57MWQgllrfQ
ISKn2nZ3uLSq4R7EyzEQIlAUlFaJw5UJDNFpI6R3faShUG+kJXdXibjey2JjpdN3
1/CHJ3C2yVQR4zoBMPR7r5tlexdGUa228e+/gadFl/aY4ESAbXiJpG4jZGc7lAmd
1Y4JHhjayiJhtKj8cgO0KDuna+Pxh+RkWAyO7nOUMfRqY7QuDMapM6d/dMetZbz4
yMTPZWQi317HZ1racD0omr/siCS0JCbjjedpyz85yYnqKLE08gW9uB3p6gzdVtxN
n8BaVyPtjbuezFUNFfkGS5MRuVYc6B9LAgMBAAGjZjBkMB0GA1UdDgQWBBS9u6Ea
2J0Z3PKsZ6CLETBxMQV8jjAfBgNVHSMEGDAWgBTMI6hSlcDMBNJZH9huHeUWWU2s
9jASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0B
AQsFAAOCAgEAjb0+EdZFnNHKvo0LhFHGqncCzv+O0X8uWtgHAx0p304sMWyOV2qe
tHFiZtJ47M8Ru3jE82kL6Wxieich7N9s+CrdXJXR2Eh6loJDtNBP8nQIUTTIGSqe
Wnf4sqn2bw2puIA6C0D0PKPvq4BFt7Br/pxfRJ4fN3ksr9LtBqhy0qcfMmhC6qsb
jhWCROZwBnTXHcd65d1Np9mRnFTXemARX8x5EX7uNVq3wT93emfi37OkxZMRq9xK
CMzZKuKZ2TGAprfAftba9upZmEN9rlWXT4mgEA29qebt2/Vn+QAA06BLY4dyPIgn
rrRx5ogdRRsw3uStksc0ef1Nk/nGQEI+NcG/ZTV0fltf6c4SIMysQ/qDIshCUe5P
tfypBO/kzNcseiZA6jGyVSGrKmSwjoyRdH7aT2PnymOMZ5Joce8jxD2TjrnieG0W
63/p02qR48w2qkd3We+W1S4o2cZaS//o4xr4mxG6+/p9f8ubIDzfctS53hprQpmu
EFxzSP2PPURazefDXy9nmxjHv3QjrBDc9qqI6KhnegGETB+Aio+EEKA/0npLDtF1
SPHgaFG27p1UqRJNS+H7S9C0jXCEjZPNIfn4P42JGiCl8tFAXRBcHI5+7FiRGaGz
rwg2KJfv9Rg3Z32y7lrIdgbqEsyYove0d6TpQACp2VRRXjn+H0l1yc8=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIGCDCCA/CgAwIBAgIJAIKsMAZuH8qDMA0GCSqGSIb3DQEBCwUAMIGQMQswCQYD
VQQGEwJJTjELMAkGA1UECAwCTUgxDTALBgNVBAcMBFBVTkUxDzANBgNVBAoMBlRS
SUxJTzELMAkGA1UECwwCSVQxGjAYBgNVBAMMESoudHJpbGlvZGF0YS5kZW1vMSsw
KQYJKoZIhvcNAQkBFhxwcmFzaGFudC5zYWtoYXJrYXJAdHJpbGlvLmlvMB4XDTE5
MDYxMzA4NTQyOFoXDTM5MDYwODA4NTQyOFowgZAxCzAJBgNVBAYTAklOMQswCQYD
VQQIDAJNSDENMAsGA1UEBwwEUFVORTEPMA0GA1UECgwGVFJJTElPMQswCQYDVQQL
DAJJVDEaMBgGA1UEAwwRKi50cmlsaW9kYXRhLmRlbW8xKzApBgkqhkiG9w0BCQEW
HHByYXNoYW50LnNha2hhcmthckB0cmlsaW8uaW8wggIiMA0GCSqGSIb3DQEBAQUA
A4ICDwAwggIKAoICAQDUQzq9ki4L5/QhgJtyUQXTli/WyYlXF6TqYbVUkl/N4AE0
QkfwAPFz+wWW3WDY1xAUIuQMkmf8V4SnCA+zD9cQvTCsB4ScBejknvQiV275o9TH
DCyUxRuuVDTQ9q0tLQUOLa4RH/ytbVwdQ9+G1jU3elqQfGCpQwO9ZCHSXwypmVJW
plgRqrq1FGx2fjgchTawSIrE0E2Wtd4rUaYG+jx6gD3TnrzDuapsTSaBjyc9bJRm
eEJvkde/q8G94qaxuAk+UQelYoR+Pk1JSS8OILloG6R5TQJQf5o4DEmvZbv/kaCi
AA7e6kyYhZ8dT1gi8ux965c1fIDZH1e4Qm30KCbJ6pGYfaQq9UlzZLggH+EFbXQM
rGZwWomckCIIKumWNFFtJ9BpirMjm4TjhNZnS9EmjUQC41eBX/3bvj5QnG1PnnPA
87CnKJEXlTEWVtdz3G+XuH4qvbeW/pmV4hpQ/lmkidVMNIfYtnTcW0Qd7HG4oczb
BETjCibFyMJndyIhJDTmvhrEEfLmJbm4P2OZ6Yjb+yd+eqJJhcCvfS31J6Ex2kMb
xJD9MOygDrtdjLUSlpVdJTA6eSEHgbGUDoBv5wPe/bxot8ccdGyWj5Ch5EGUxJRQ
3ZvsmNq2e8y0rIa/MDh4MICNSNM+lVoEYeaeuqLN+Ml18yZQLy/mf44C2A5OxQID
AQABo2MwYTAdBgNVHQ4EFgQUzCOoUpXAzATSWR/Ybh3lFllNrPYwHwYDVR0jBBgw
FoAUzCOoUpXAzATSWR/Ybh3lFllNrPYwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8B
Af8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBAMX4TVDmrT9NzkmKh6Pnn6jX7lft
lpU+WewMMs97Vdwd8lnAn9lpBP9q0xyAVtJpmcPVHc6NlQBazf5nqhx2u9/LUPNP
zdYRz7X/xu71ePzX7UCh+s4kftf/Hokwi4jF/QtnmRvFRp7Y8+OIEf0sz6jkW552
hj43UTFDLpYWdfCNeBH+j9RjzWJHKdvRwEPzpmYp/KbgBagerp8BSQqEBc7sQMXw
r0Wyip3FaKEon+NMMavrFnNcQALMG68IZf4CnF9X2MSUMTfZj86KiPcpwbbfSRwU
RFL7Ia7uX9+UxewAJdcjNVpERhTHu0ucFA5Ea56sLK/nd5kg5Or1d5noeTODhAFu
SAcT3yblzxoXoV1+pvm7PslMVWd+P/zxwucaLb4ll5BZWml7xZAgc/KIwnkyU+Yg
yX//RN8REGUAPYsi0LkrOAJubmI1Tbr8cgmsxG2kCPMyoyKpM3AociW7mHneu6EX
PIiLWm87o+dbeoPNibTkNBqN6uGpHGxspEma/r87fUiMsjj75NxvGw8D+NpynOIf
D6tmcLSXaJrZ+PXkX2iqss+iM4Y5FHWHlTVcqZ4kcrqNcOtO0SUtpZKCk7uZVJpa
mQiHr3IX9CMfGAgHOZUchA9gzz5vihg5ASrCLShdwifWrFqqSWMHEFVU+A+84Yg4
+BWLC6oxhDE+OEjS
-----END CERTIFICATE-----"

# ---------------------------------------------------------------------------
# Step 1: Generate S3 secret payloads via trilio-dms-cli inside the WLM pod
# ---------------------------------------------------------------------------

echo "=== Step 1: Generating S3 secret payloads ==="

echo "  Writing BT1 CA cert to pod..."
printf '%s' "$BT1_CA_CERT" | kubectl exec -i -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  bash -c "cat > /tmp/bt1-ca.pem"

echo "  Generating BT1_S3 payload (Ceph RGW, CA cert)..."
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  env VAULT_S3_ACCESS_KEY_ID="$BT1_S3_ACCESS_KEY" \
      VAULT_S3_SECRET_ACCESS_KEY="$BT1_S3_SECRET_KEY" \
  trilio-dms-cli secret-payload create \
    --bucket        "trilio-automation" \
    --endpoint-url  "https://cephquincy.triliodata.demo" \
    --filesystem-export "cephquincy.triliodata.demo/trilio-automation" \
    --region            "us-east-1" \
    --auth-version      "DEFAULT" \
    --signature-version "default" \
    --ssl \
    --ssl-verify \
    --ssl-cert /tmp/bt1-ca.pem \
    -o /tmp/bt1_s3_secret.json

kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- rm -f /tmp/bt1-ca.pem

echo "  Generating BT2_S3 payload (Wasabi)..."
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
  env VAULT_S3_ACCESS_KEY_ID="$BT2_S3_ACCESS_KEY" \
      VAULT_S3_SECRET_ACCESS_KEY="$BT2_S3_SECRET_KEY" \
  trilio-dms-cli secret-payload create \
    --bucket        "qa-sachin" \
    --endpoint-url  "https://s3.wasabisys.com" \
    --filesystem-export "s3.wasabisys.com/qa-sachin" \
    --region            "us-east-1" \
    --auth-version      "DEFAULT" \
    --signature-version "default" \
    --ssl \
    --ssl-verify \
    -o /tmp/bt2_s3_secret.json

# Copy payloads out of pod
BT1_PAYLOAD=$(kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- cat /tmp/bt1_s3_secret.json)
BT2_PAYLOAD=$(kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- cat /tmp/bt2_s3_secret.json)
kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- rm -f /tmp/bt1_s3_secret.json /tmp/bt2_s3_secret.json

echo "  Payloads generated."

# ---------------------------------------------------------------------------
# Step 2: Deploy minimal secret-server in Kubernetes
#
# Barbican is not deployed in Sunbeam by default. The secret-server is a
# lightweight Python HTTP pod that serves the DMS secret payloads over HTTP
# on a ClusterIP. MicroK8s ClusterIPs are reachable from the host machine
# (DataMover compute side) via the bridge network — the same route used by
# workloadmgr's own Keystone auth_url.
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

echo "  Creating BT1_S3 (Ceph, default)..."
wlm_exec workloadmgr backup-target-create \
  --btt-name "BT1_S3" \
  --type s3 \
  --s3-endpoint-url "https://cephquincy.triliodata.demo" \
  --s3-bucket "trilio-automation" \
  --secret-ref "$BT1_SECRET_REF" \
  --default \
  -f json

echo ""
echo "  Creating BT2_S3 (Wasabi)..."
wlm_exec workloadmgr backup-target-create \
  --btt-name "BT2_S3" \
  --type s3 \
  --s3-endpoint-url "https://s3.wasabisys.com" \
  --s3-bucket "qa-sachin" \
  --secret-ref "$BT2_SECRET_REF" \
  -f json

# ---------------------------------------------------------------------------
# Step 4: Create NFS backup target
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Creating NFS backup target ==="
echo "  NFS export: $NFS_SERVER_EXPORT"

wlm_exec workloadmgr backup-target-create \
  --btt-name "$NFS_TARGET_NAME" \
  --type nfs \
  --filesystem-export "$NFS_SERVER_EXPORT" \
  --nfs-mount-opts "$NFS_MOUNT_OPTS" \
  -f json

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo ""
echo "=== Backup target list ==="
wlm_exec workloadmgr backup-target-list
