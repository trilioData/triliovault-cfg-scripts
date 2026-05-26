#!/bin/bash
# recreate_backup_targets.sh
#
# Creates backup targets in T4O 6.2 after upgrading from T4O 5.x/6.0/6.1.
# Use this after upgrading the Juju charms and after running unmount_old_backup_targets.sh.
#
# Reads backup target config from existing_backup_targets.json produced by
# collect_backup_targets.sh (run that script BEFORE the upgrade).
#
# For S3 targets: credentials are stored in OpenStack Barbican and the backup
# target is created with a Barbican secret reference (same as kolla-ansible upgrade).
# For NFS targets: created directly via workloadmgr.
#
# Prerequisites:
#   - existing_backup_targets.json produced by collect_backup_targets.sh
#   - T4O 6.2 charms are deployed and all units are active/idle
#   - python3 with PyYAML (pip3 install pyyaml)
#   - workloadmgr CLI (T4O 6.2)
#   - openstack CLI (for Barbican — S3 targets only)
#   - trilio-dms-cli (for S3 targets only)
#   - OpenStack credentials sourced (or provided via --openrc)
#
# Usage:
#   bash recreate_backup_targets.sh \
#     [-f existing_backup_targets.json] \
#     [--openrc /path/to/admin-openrc.sh]
#
# For non-interactive S3 migration (CI/automation):
#   export TRILIOVAULT_S3_SECRET_KEY=<secret>
#   bash recreate_backup_targets.sh -f existing_backup_targets.json --openrc /path/to/openrc

set -e

COLLECTED_FILE="existing_backup_targets.json"
OPENRC=""
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)   COLLECTED_FILE="$2"; shift 2 ;;
    --openrc)    OPENRC="$2";         shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -f <collected.json> --openrc <openrc>" ;;
  esac
done

[ -f "$COLLECTED_FILE" ] || die "Collected file not found: $COLLECTED_FILE. Run collect_backup_targets.sh first."
command -v python3     >/dev/null 2>&1 || die "python3 not found."
command -v workloadmgr >/dev/null 2>&1 || die "workloadmgr CLI not found. Ensure T4O 6.2 is running and CLI is installed."

if [ -n "$OPENRC" ]; then
    [ -f "$OPENRC" ] || die "OpenRC file not found: $OPENRC"
    # shellcheck disable=SC1090
    source "$OPENRC"
fi

log_step "Reading backup targets from $COLLECTED_FILE"

COUNT=$(python3 -c "
import json
d = json.load(open('$COLLECTED_FILE'))
targets = d.get('backup_targets', d if isinstance(d, list) else [])
print(len(targets))
")
log "Found $COUNT backup target(s) to create."

export _COLLECTED_FILE="$COLLECTED_FILE"
export _TMPDIR="$TMPDIR"

python3 - <<'PYEOF'
import json, os, sys, subprocess

collected_file = os.environ['_COLLECTED_FILE']
tmpdir = os.environ['_TMPDIR']

data = json.load(open(collected_file))
targets = data.get('backup_targets', data if isinstance(data, list) else [])

def run(cmd, check=True):
    print("    CMD: " + ' '.join(str(c) for c in cmd[:10]) + (' ...' if len(cmd) > 10 else ''))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        print("    STDERR: " + result.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return result

def get_barbican_endpoint():
    r = run(['openstack', 'endpoint', 'list',
             '--service', 'key-manager', '--interface', 'public', '-f', 'json'])
    eps = json.loads(r.stdout)
    if not eps:
        print("ERROR: No public Barbican endpoint found.", file=sys.stderr)
        sys.exit(1)
    url = eps[0]['URL'].rstrip('/')
    if url.endswith('/v1'):
        url = url[:-3]
    return url

for i, target in enumerate(targets):
    name = target.get('backup-target-name', 'backup-target-{}'.format(i+1))
    btype = target.get('backup-target-type', '').lower()
    is_default = str(target.get('is-default', False)).lower()

    print()
    print("================================================================")
    print("[{}/{}] Creating backup target: {} (type: {})".format(i+1, len(targets), name, btype))
    print("================================================================")

    if btype == 'nfs':
        nfs_shares = target.get('nfs-shares', '')
        nfs_options = target.get('nfs-options', '')

        if not nfs_shares:
            print("  ERROR: nfs-shares is empty for '{}'. Skipping.".format(name), file=sys.stderr)
            continue

        print("  NFS shares  : " + nfs_shares)
        print("  NFS options : " + (nfs_options or '(none)'))

        cmd = ['workloadmgr', 'backup-target-create',
               '--name', name,
               '--type', 'nfs',
               '--nfs-shares', nfs_shares,
               '--is-default', is_default]
        if nfs_options:
            cmd += ['--nfs-options', nfs_options]
        run(cmd)
        print("  SUCCESS: NFS backup target '{}' created.".format(name))

    elif btype == 's3':
        s3_type       = target.get('s3-type', 'amazon_s3')
        s3_access_key = target.get('s3-access-key', '')
        s3_secret_key = target.get('s3-secret-key', '')
        s3_bucket     = target.get('s3-bucket', '')
        s3_region     = target.get('s3-region-name', '')
        s3_endpoint   = target.get('s3-endpoint-url', '')

        if not s3_access_key or not s3_bucket:
            print("  ERROR: s3-access-key or s3-bucket is empty for '{}'. Skipping.".format(name), file=sys.stderr)
            continue

        # Get or prompt for secret key
        if os.environ.get('TRILIOVAULT_S3_SECRET_KEY'):
            s3_secret_key = os.environ['TRILIOVAULT_S3_SECRET_KEY']
            print("  S3 secret key : (from env TRILIOVAULT_S3_SECRET_KEY)")
        elif not s3_secret_key or s3_secret_key == 'REDACTED':
            s3_secret_key = input("  Enter S3 secret key for '{}': ".format(name)).strip()
            if not s3_secret_key:
                print("  ERROR: S3 secret key cannot be empty. Skipping.", file=sys.stderr)
                continue

        print("  S3 type       : " + s3_type)
        print("  S3 access key : " + s3_access_key)
        print("  S3 bucket     : " + s3_bucket)
        print("  S3 region     : " + (s3_region or '(default)'))
        print("  S3 endpoint   : " + (s3_endpoint or '(default)'))

        # Store credentials in Barbican via trilio-dms-cli
        print("  Resolving public Barbican endpoint...")
        barbican_url = get_barbican_endpoint()
        print("  Barbican URL  : " + barbican_url)

        payload_file = os.path.join(tmpdir, 'secret_payload_{}.json'.format(i))
        dms_cmd = ['trilio-dms-cli', 'secret-payload', 'create',
                   '--access-key', s3_access_key,
                   '--secret-key', s3_secret_key,
                   '--bucket',     s3_bucket,
                   '-o',           payload_file]
        if s3_endpoint:
            dms_cmd += ['--endpoint-url', s3_endpoint]
        run(dms_cmd)

        secret_name = 'trilio-s3-{}'.format(name.replace(' ', '-'))
        print("  Storing secret in Barbican as: " + secret_name)
        r = run(['openstack', 'secret', 'store',
                 '--name', secret_name,
                 '--payload', open(payload_file).read(),
                 '--format', 'json'])
        secret_data = json.loads(r.stdout)
        secret_href = secret_data.get('Secret href', '')
        if not secret_href:
            print("  ERROR: Could not extract Barbican secret href.", file=sys.stderr)
            sys.exit(1)

        # Normalize to public endpoint
        secret_uuid = secret_href.rstrip('/').split('/')[-1]
        secret_href = '{}/v1/secrets/{}'.format(barbican_url, secret_uuid)
        print("  Barbican secret: " + secret_href)

        run(['workloadmgr', 'backup-target-create',
             '--name', name,
             '--type', s3_type,
             '--secret-ref', secret_href,
             '--is-default', is_default])
        print("  SUCCESS: S3 backup target '{}' created.".format(name))

    else:
        print("  WARNING: Unknown backup target type '{}' — skipping.".format(btype))

print()
print("================================================================")
print("All backup targets processed. Verifying...")
print("================================================================")
PYEOF

log_step "Verification"
workloadmgr backup-target-list
log ""
log "Done. Verify all targets show 'available' status before triggering a backup."
