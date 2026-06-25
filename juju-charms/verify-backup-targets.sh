#!/bin/bash
# verify-backup-targets.sh
#
# Manually verifies Barbican + S3 backup target creation end-to-end.
# Reads S3 target details from the previous-release overlay bundle YAML.
# Run this on the trilio-wlm unit AFTER upgrading to T4O 6.2.
#
# Usage:
#   bash verify-backup-targets.sh /path/to/old-overlay-bundle.yaml

set -e

BUNDLE="${1:-/home/ubuntu/tvo-overlay-bundle.yaml}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

[ -f "$BUNDLE" ] || { echo "ERROR: Bundle not found: $BUNDLE"; exit 1; }
command -v workloadmgr    >/dev/null || { echo "ERROR: workloadmgr not found"; exit 1; }
command -v trilio-dms-cli >/dev/null || { echo "ERROR: trilio-dms-cli not found"; exit 1; }
command -v openstack      >/dev/null || { echo "ERROR: openstack CLI not found"; exit 1; }

echo "=== Reading S3 backup targets from bundle ==="

python3 - <<PYEOF
import json, yaml, sys

with open("$BUNDLE") as f:
    bundle = yaml.safe_load(f)

apps = bundle.get('applications', {})
raw = None
for app in ('trilio-wlm', 'trilio-data-mover'):
    raw = apps.get(app, {}).get('options', {}).get('trilio-backup-targets')
    if raw:
        break

if not raw:
    print("ERROR: trilio-backup-targets not found in bundle")
    sys.exit(1)

targets = json.loads(raw)
s3_targets = [t for t in targets if t.get('backup-target-type', '').lower() == 's3']

if not s3_targets:
    print("No S3 targets found in bundle.")
    sys.exit(0)

print(f"Found {len(s3_targets)} S3 target(s):")
for t in s3_targets:
    print(f"  - {t.get('backup-target-name')}  bucket={t.get('s3-bucket')}")

with open("$TMPDIR/s3_targets.json", "w") as f:
    json.dump(s3_targets, f)
PYEOF

echo ""
echo "=== Processing S3 targets ==="

python3 - <<PYEOF
import json, os, subprocess, sys, getpass
from urllib.parse import urlparse

targets = json.load(open("$TMPDIR/s3_targets.json"))

for i, t in enumerate(targets):
    name        = t.get('backup-target-name', f'bt-{i}')
    bucket      = t.get('s3-bucket', '')
    endpoint    = t.get('s3-endpoint-url', '')
    access_key  = t.get('s3-access-key', '')
    secret_key  = t.get('s3-secret-key', '')
    ssl_enabled = t.get('s3-ssl-enabled', False)
    ssl_verify  = t.get('s3-ssl-verify', False)
    ca_cert     = t.get('s3-ssl-ca_cert', '')

    print(f"\n--- [{i+1}/{len(targets)}] {name} ---")

    # Prompt for credentials if missing or redacted
    if not access_key or access_key.upper() in ('REMOVED', 'REDACTED', ''):
        access_key = input(f"  Enter s3-access-key for '{name}': ").strip()
    if not secret_key or secret_key.upper() in ('REMOVED', 'REDACTED', ''):
        secret_key = getpass.getpass(f"  Enter s3-secret-key for '{name}': ").strip()

    if not access_key or not secret_key:
        print(f"  SKIP: credentials empty for '{name}'")
        continue

    # Build filesystem-export for trilio-dms-cli
    if endpoint:
        host = urlparse(endpoint).hostname
        fs_export = f"{host}/{bucket}"
    else:
        fs_export = bucket

    # Write CA cert to temp file if provided
    cert_path = None
    if ca_cert and ca_cert.upper() not in ('REMOVED', 'REDACTED') and ssl_verify:
        cert_path = f"$TMPDIR/ca_cert_{i}.pem"
        with open(cert_path, 'w') as cf:
            cf.write(ca_cert)

    # Step 1: Create DMS secret payload
    payload_file = f"$TMPDIR/payload_{i}.json"
    dms_cmd = [
        'trilio-dms-cli', 'secret-payload', 'create',
        '--access-key', access_key,
        '--secret-key', secret_key,
        '--bucket',     bucket,
        '--filesystem-export', fs_export,
        '-o', payload_file,
    ]
    if endpoint:
        dms_cmd += ['--endpoint-url', endpoint]
    dms_cmd.append('--ssl' if ssl_enabled else '--no-ssl')
    if ssl_verify and cert_path:
        dms_cmd += ['--ssl-verify', '--ssl-cert', cert_path]
    else:
        dms_cmd.append('--no-ssl-verify')

    r = subprocess.run(dms_cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL: trilio-dms-cli: {r.stderr.strip()}")
        continue
    print("  PASS: DMS secret payload created")

    # Step 2: Store payload in Barbican
    payload = open(payload_file).read().strip()
    r = subprocess.run(
        ['openstack', 'secret', 'store',
         '--name', f'verify-{name}',
         '--payload', payload,
         '-f', 'json'],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL: openstack secret store: {r.stderr.strip()}")
        continue

    store_data = json.loads(r.stdout)
    if isinstance(store_data, list):
        store_data = store_data[0]
    secret_href = store_data.get('Secret href', '')

    if not secret_href or 'None' in secret_href:
        print("  FAIL: Barbican returned invalid secret href — host_href not configured")
        if secret_href:
            subprocess.run(['openstack', 'secret', 'delete', secret_href],
                           capture_output=True)
        continue
    print("  PASS: Barbican secret stored")

    # Step 3: Create backup target
    bt_cmd = ['workloadmgr', 'backup-target-create',
              '--type', 's3',
              '--btt-name', name,
              '--s3-bucket', bucket,
              '--secret-ref', secret_href]
    if endpoint:
        bt_cmd += ['--s3-endpoint-url', endpoint]
    if i == 0:
        bt_cmd.append('--default')
    r = subprocess.run(bt_cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL: backup-target-create: {r.stderr.strip()}")
        subprocess.run(['openstack', 'secret', 'delete', secret_href],
                       capture_output=True)
        continue
    print(f"  PASS: backup target '{name}' created")

print()
PYEOF

echo "=== Final backup target list ==="
workloadmgr backup-target-list
