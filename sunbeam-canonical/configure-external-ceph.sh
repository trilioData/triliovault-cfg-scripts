#!/usr/bin/env bash
# configure-external-ceph.sh — wire trilio-data-mover to an EXTERNAL Ceph cluster.
#
# For a Ceph cluster deployed outside Sunbeam (cephadm, Rook, or other
# third-party tooling) that Cinder and/or Nova already use. It does everything
# after you have created the Ceph client:
#
#   1. validates the ceph.conf and keyring you pass in
#   2. sets ceph-enabled / internal-ceph-enabled / trilio-ceph-username
#   3. loads ceph.conf into the charm config
#   4. creates the Juju secret for the keyring, grants it to the application,
#      and points the charm at it
#   5. waits for the units to settle and verifies Ceph access from each one
#
# NOT for Sunbeam's own microceph. That path is fully automated by the ceph
# relation in trilio-dataplane-bundle.yaml — do not run this script for it.
#
# Usage:
#   ./configure-external-ceph.sh --ceph-conf <file> --keyring <file> [options]
#
#   --ceph-conf <file>   ceph.conf from the external cluster (required)
#   --keyring <file>     keyring for the Trilio Ceph client (required)
#   --client <name>      Ceph client name. Default: read from the keyring's
#                        [client.X] stanza.
#   --app <name>         Juju application. Default: trilio-data-mover
#   --model <name>       Juju model. Default: current model
#   --secret-name <name> Juju secret label. Default: <app>-ceph-keyring
#   --pool <name>        RBD pool to verify access against. Repeatable.
#                        Skipped if not given.
#   --dry-run            Print what would run, change nothing.
#
# Re-runnable: an existing secret is updated rather than recreated.

set -uo pipefail

CEPH_CONF="" KEYRING="" CLIENT="" APP="trilio-data-mover"
MODEL="" SECRET_NAME="" DRY_RUN=0
POOLS=()

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ceph-conf)   CEPH_CONF="$2"; shift 2 ;;
        --keyring)     KEYRING="$2";   shift 2 ;;
        --client)      CLIENT="$2";    shift 2 ;;
        --app)         APP="$2";       shift 2 ;;
        --model)       MODEL="$2";     shift 2 ;;
        --secret-name) SECRET_NAME="$2"; shift 2 ;;
        --pool)        POOLS+=("$2");  shift 2 ;;
        --dry-run)     DRY_RUN=1;      shift ;;
        -h|--help)     sed -n '2,33p' "$0"; exit 0 ;;
        *)             die "Unknown argument: $1  (try --help)" ;;
    esac
done

[[ -n "$CEPH_CONF" ]] || die "--ceph-conf is required"
[[ -n "$KEYRING"   ]] || die "--keyring is required"
[[ -r "$CEPH_CONF" ]] || die "Cannot read ceph.conf: $CEPH_CONF"
[[ -r "$KEYRING"   ]] || die "Cannot read keyring: $KEYRING"

MODEL_ARG=()
[[ -n "$MODEL" ]] && MODEL_ARG=(-m "$MODEL")

command -v juju >/dev/null 2>&1 || die "juju is not on PATH"

# ---------------------------------------------------------------------------
# 1. Validate the inputs before touching anything
# ---------------------------------------------------------------------------
step "Validating inputs"

grep -qiE '^[[:space:]]*mon[ _]host' "$CEPH_CONF" \
    || die "$CEPH_CONF has no 'mon host' line. The DataMover cannot reach the
  cluster without it — copy the ceph.conf your Cinder/Nova nodes already use."

# The client name comes from the keyring unless overridden, so the keyring and
# the charm's rbd_user cannot silently disagree.
KEYRING_CLIENT="$(sed -n 's/^[[:space:]]*\[client\.\([^]]*\)\].*/\1/p' "$KEYRING" | head -1)"
if [[ -z "$CLIENT" ]]; then
    [[ -n "$KEYRING_CLIENT" ]] \
        || die "Could not find a [client.X] stanza in $KEYRING, and --client was
  not given. Pass --client <name> explicitly."
    CLIENT="$KEYRING_CLIENT"
    info "  client name (from keyring): $CLIENT"
elif [[ -n "$KEYRING_CLIENT" && "$KEYRING_CLIENT" != "$CLIENT" ]]; then
    die "--client is '$CLIENT' but $KEYRING contains [client.$KEYRING_CLIENT].
  These must match, or the DataMover authenticates as a client whose key it
  does not have. Fix one of them."
else
    info "  client name: $CLIENT"
fi

grep -qE '^[[:space:]]*key[[:space:]]*=' "$KEYRING" \
    || die "$KEYRING has no 'key =' line — it does not look like a Ceph keyring."

# `juju status <name>` exits 0 for an application that does not exist — the
# name is treated as a filter pattern that simply matches nothing. So check the
# parsed output instead, or a typo'd --app silently "passes" here and fails
# later on a confusing juju config error.
juju status "${MODEL_ARG[@]}" --format=json 2>/dev/null \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if '$APP' in (d.get('applications') or {}) else 1)
" 2>/dev/null \
    || die "Juju application '$APP' not found${MODEL:+ in model $MODEL}.
  Deploy the data plane first, using trilio-dataplane-bundle-no-microceph.yaml.
  Check the name and model with: juju status"

info "  ceph.conf: $CEPH_CONF"
info "  keyring:   $KEYRING"
info "  juju app:  $APP${MODEL:+  (model $MODEL)}"

[[ -z "$SECRET_NAME" ]] && SECRET_NAME="${APP}-ceph-keyring"

# ---------------------------------------------------------------------------
# 2. Flags and client name
# ---------------------------------------------------------------------------
step "Configuring $APP for an external Ceph cluster"
run juju config "${MODEL_ARG[@]}" "$APP" \
    ceph-enabled=true \
    internal-ceph-enabled=false \
    trilio-ceph-username="$CLIENT"
info "  ceph-enabled=true  internal-ceph-enabled=false  trilio-ceph-username=$CLIENT"

# ---------------------------------------------------------------------------
# 3. ceph.conf — plain config, it holds no secret
# ---------------------------------------------------------------------------
step "Loading ceph.conf"
if [[ $DRY_RUN -eq 1 ]]; then
    printf '  [dry-run] juju config %s ceph-conf="$(cat %s)"\n' "$APP" "$CEPH_CONF"
else
    juju config "${MODEL_ARG[@]}" "$APP" ceph-conf="$(cat "$CEPH_CONF")" \
        || die "Failed to set ceph-conf"
fi
info "  loaded $(wc -l < "$CEPH_CONF") lines"

# ---------------------------------------------------------------------------
# 4. Keyring — a Juju secret, never plain config
#
# The keyring is a cephx credential. As a secret it stays out of the
# controller's config store, `juju config` output, and `juju export-bundle`.
# ---------------------------------------------------------------------------
step "Storing the keyring as a Juju secret"

existing_id() {
    juju secrets "${MODEL_ARG[@]}" --format=json 2>/dev/null \
      | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for sid, s in (d or {}).items():
    if s.get('label') == '$SECRET_NAME':
        print(sid); break
" 2>/dev/null
}

SECRET_ID="$(existing_id)"

if [[ -n "$SECRET_ID" ]]; then
    info "  secret '$SECRET_NAME' exists ($SECRET_ID) — updating it"
    run juju update-secret "${MODEL_ARG[@]}" "$SECRET_NAME" "keyring#file=$KEYRING" \
        || die "Failed to update secret $SECRET_NAME"
    [[ "$SECRET_ID" == secret:* ]] || SECRET_ID="secret:$SECRET_ID"
else
    info "  creating secret '$SECRET_NAME'"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] juju add-secret %s keyring#file=%s\n' "$SECRET_NAME" "$KEYRING"
        SECRET_ID="secret:DRYRUN"
    else
        SECRET_ID="$(juju add-secret "${MODEL_ARG[@]}" "$SECRET_NAME" \
                     "keyring#file=$KEYRING" 2>&1 | tr -d '\r' | tail -1)"
        [[ "$SECRET_ID" == secret:* ]] \
            || die "add-secret did not return a secret URI. Output was: $SECRET_ID"
    fi
fi
info "  secret id: $SECRET_ID"

# The grant is what lets the application read it. Without this the charm gets
# SecretNotFoundError at hook time — Juju does not distinguish "absent" from
# "not authorised".
step "Granting the secret to $APP"
run juju grant-secret "${MODEL_ARG[@]}" "$SECRET_NAME" "$APP" \
    || die "Failed to grant secret $SECRET_NAME to $APP"

step "Pointing $APP at the secret"
run juju config "${MODEL_ARG[@]}" "$APP" ceph-keyring="$SECRET_ID" \
    || die "Failed to set ceph-keyring"

if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. Nothing was changed.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Settle and verify
# ---------------------------------------------------------------------------
step "Waiting for $APP to settle"
juju wait-for application "${MODEL_ARG[@]}" "$APP" \
    --query='status=="active"' --timeout=10m 2>/dev/null \
    || info "  (not active yet — check 'juju status $APP' below)"

juju status "${MODEL_ARG[@]}" "$APP" 2>/dev/null | sed 's/^/  /'

if [[ ${#POOLS[@]} -eq 0 ]]; then
    cat <<EOF

Done. No --pool given, so Ceph access was not verified.

Verify by hand on any compute node — this is the check that actually proves the
credential works:

  juju ssh ${MODEL:+-m $MODEL }$APP/0 -- sudo rbd --id $CLIENT ls <cinder-pool>

Find <cinder-pool> with:

  openstack volume backend pool list      # the part after '#' is the pool
EOF
    exit 0
fi

step "Verifying Ceph access from every unit"
units="$(juju status "${MODEL_ARG[@]}" "$APP" --format=json 2>/dev/null \
         | python3 -c "
import json,sys
d=json.load(sys.stdin)
out=set()
for a in d.get('applications',{}).values():
    for u,ud in (a.get('units') or {}).items():
        if u.startswith('$APP/'): out.add(u)
        for s in (ud.get('subordinates') or {}):
            if s.startswith('$APP/'): out.add(s)
for u in sorted(out): print(u)
" 2>/dev/null)"

[[ -n "$units" ]] || die "Could not enumerate units of $APP"

rc=0
for unit in $units; do
    for pool in "${POOLS[@]}"; do
        if juju ssh "${MODEL_ARG[@]}" --pty=false "$unit" -- \
             "sudo rbd --id $CLIENT ls $pool" </dev/null >/dev/null 2>&1; then
            info "  PASS  $unit -> $pool"
        else
            info "  FAIL  $unit -> $pool"
            rc=1
        fi
    done
done

if [[ $rc -ne 0 ]]; then
    caps="$(printf "profile rbd pool=%s, " "${POOLS[@]}" | sed 's/, $//')"
    cat >&2 <<EOF

At least one unit cannot read a pool as client.$CLIENT. Usually the client is
missing rwx on that pool. Re-grant on a Ceph admin node:

  ceph auth caps client.$CLIENT mon 'profile rbd' osd '$caps'
EOF
    exit 1
fi

printf '\nExternal Ceph configured and verified.\n'
