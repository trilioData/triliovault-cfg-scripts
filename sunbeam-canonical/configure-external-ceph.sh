#!/usr/bin/env bash
# configure-external-ceph.sh — wire trilio-data-mover to an EXTERNAL Ceph cluster.
#
# For a Ceph cluster deployed outside Sunbeam (cephadm, Rook, or other
# third-party tooling) that Cinder and/or Nova already use. It does everything
# after you have created the Ceph client:
#
#   1. validates the ceph.conf and keyring you pass in
#   2. writes ceph-enabled / internal-ceph-enabled / trilio-ceph-username and
#      the ceph.conf contents into the deployment bundle
#   3. creates the Juju secret for the keyring, grants it to the application,
#      and points the charm at it
#   4. applies the same values to the running application, when it is deployed
#   5. waits for the units to settle and verifies Ceph access from each one
#
# ceph.conf goes in the bundle because it holds no secret and belongs under
# version control with the rest of the deployment. The keyring is a cephx
# credential and only ever goes into a Juju secret.
#
# NOT for Sunbeam's own microceph. That path is fully automated by the ceph
# relation in trilio-dataplane-bundle.yaml — do not run this script for it.
#
# Usage:
#   ./configure-external-ceph.sh --ceph-conf <file> --keyring <file> [options]
#
#   --ceph-conf <file>   ceph.conf from the external cluster (required)
#   --keyring <file>     keyring for the Trilio Ceph client (required)
#   --bundle <file>      Bundle to write ceph-conf into. Default:
#                        trilio-dataplane-bundle-external-ceph.yaml beside this
#                        script. Comments and unrelated keys are preserved.
#   --no-bundle          Do not touch any bundle; configure the live app only.
#   --client <name>      Ceph client name. Default: read from the keyring's
#                        [client.X] stanza.
#   --app <name>         Juju application. Default: trilio-data-mover
#   --model <name>       Juju model. Default: current model
#   --secret-name <name> Juju secret label. Default: <app>-ceph-keyring
#   --pool <name>        RBD pool to verify access against. Repeatable.
#                        Skipped if not given.
#   --dry-run            Print what would run, change nothing.
#
# Run it before deploying — it prepares the bundle and the secret, then prints
# the deploy and grant steps — or after, when it also configures the live app.
#
# Re-runnable: an existing secret is updated rather than recreated.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CEPH_CONF="" KEYRING="" CLIENT="" APP="trilio-data-mover"
MODEL="" SECRET_NAME="" DRY_RUN=0
BUNDLE="${SCRIPT_DIR}/trilio-dataplane-bundle-external-ceph.yaml"
USE_BUNDLE=1
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
        --bundle)      BUNDLE="$2"; USE_BUNDLE=1; shift 2 ;;
        --no-bundle)   USE_BUNDLE=0;   shift ;;
        --pool)        POOLS+=("$2");  shift 2 ;;
        --dry-run)     DRY_RUN=1;      shift ;;
        -h|--help)     sed -n '2,44p' "$0"; exit 0 ;;
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

# Is the application deployed yet? The script is useful either way: before
# deploy it prepares the bundle and the secret, after deploy it also configures
# the live application.
#
# `juju status <name>` exits 0 for an application that does not exist — the
# name is treated as a filter pattern that simply matches nothing — so check
# the parsed output instead.
APP_DEPLOYED=0
if juju status "${MODEL_ARG[@]}" --format=json 2>/dev/null \
     | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if '$APP' in (d.get('applications') or {}) else 1)
" 2>/dev/null; then
    APP_DEPLOYED=1
fi

info "  ceph.conf: $CEPH_CONF"
info "  keyring:   $KEYRING"
info "  juju app:  $APP${MODEL:+  (model $MODEL)}"
if [[ $APP_DEPLOYED -eq 1 ]]; then
    info "  $APP is deployed — the bundle and the live application are both updated"
else
    info "  $APP is not deployed yet — preparing the bundle and the secret"
fi

[[ -z "$SECRET_NAME" ]] && SECRET_NAME="${APP}-ceph-keyring"

# ---------------------------------------------------------------------------
# 2. Flags and client name — live application only; for a not-yet-deployed app
#    the same three values go into the bundle in step 3.
# ---------------------------------------------------------------------------
if [[ $APP_DEPLOYED -eq 1 ]]; then
    step "Configuring $APP for an external Ceph cluster"
    run juju config "${MODEL_ARG[@]}" "$APP" \
        ceph-enabled=true \
        internal-ceph-enabled=false \
        trilio-ceph-username="$CLIENT"
    info "  ceph-enabled=true  internal-ceph-enabled=false  trilio-ceph-username=$CLIENT"
fi

# ---------------------------------------------------------------------------
# 3. ceph.conf into the bundle
#
# It holds no secret, so it belongs in the bundle where it is version-
# controlled alongside the rest of the deployment definition. The keyring does
# NOT — that goes into a Juju secret in step 4.
#
# The edit is textual rather than a YAML round-trip: these bundles carry
# extensive comments (including the revision/scale caution) that a
# load-then-dump would silently discard.
# ---------------------------------------------------------------------------
write_bundle() {
    python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import io, re, sys

bundle_path, conf_path, client, app = sys.argv[1:5]
conf = open(conf_path, encoding="utf-8").read().rstrip("\n")
lines = open(bundle_path, encoding="utf-8").read().splitlines()

CEPH_KEYS = ("ceph-enabled", "internal-ceph-enabled",
             "trilio-ceph-username", "ceph-conf")

# Find "<app>:" then its "options:" block.
app_i = next((i for i, l in enumerate(lines)
              if re.match(rf"^(\s*){re.escape(app)}:\s*$", l)), None)
if app_i is None:
    sys.exit(f"ERROR: application '{app}' not found in {bundle_path}")
app_indent = len(lines[app_i]) - len(lines[app_i].lstrip())

opt_i = None
for i in range(app_i + 1, len(lines)):
    stripped = lines[i].strip()
    ind = len(lines[i]) - len(lines[i].lstrip())
    if stripped and not stripped.startswith("#") and ind <= app_indent:
        break                      # left this application
    if re.match(r"^\s*options:\s*$", lines[i]):
        opt_i = i
        break
if opt_i is None:
    sys.exit(f"ERROR: no options: block under '{app}' in {bundle_path}")
opt_indent = len(lines[opt_i]) - len(lines[opt_i].lstrip())
key_indent = opt_indent + 2

# End of the options block.
end_i = len(lines)
for i in range(opt_i + 1, len(lines)):
    stripped = lines[i].strip()
    if not stripped or stripped.startswith("#"):
        continue
    ind = len(lines[i]) - len(lines[i].lstrip())
    if ind <= opt_indent:
        end_i = i
        break

# Drop any existing ceph-* keys, including block-scalar continuations and the
# comment block documenting them — otherwise the explanation for a key that is
# no longer there sits above the freshly written one.
out, i, removed = [], opt_i + 1, 0
while i < end_i:
    m = re.match(r"^(\s*)([A-Za-z0-9_.-]+):", lines[i])
    if m and len(m.group(1)) == key_indent and m.group(2) in CEPH_KEYS:
        removed += 1
        while out and (out[-1].strip().startswith("#") or not out[-1].strip()):
            out.pop()
        i += 1
        while i < end_i:
            nxt = lines[i]
            if not nxt.strip():
                i += 1
                continue
            if len(nxt) - len(nxt.lstrip()) > key_indent:
                i += 1
                continue
            break
        continue
    out.append(lines[i])
    i += 1

pad = " " * key_indent
block = [
    f"{pad}# --- External Ceph (written by configure-external-ceph.sh) ---",
    f"{pad}ceph-enabled: true",
    f"{pad}internal-ceph-enabled: false",
    f'{pad}trilio-ceph-username: "{client}"',
    f"{pad}ceph-conf: |",
] + [f"{pad}  {l}" if l.strip() else "" for l in conf.splitlines()]

new = lines[:opt_i + 1] + out + block + lines[end_i:]
open(bundle_path, "w", encoding="utf-8").write("\n".join(new) + "\n")
print(f"  replaced {removed} existing ceph-* key(s); wrote {len(conf.splitlines())} ceph.conf lines")
PYEOF
}

if [[ $USE_BUNDLE -eq 1 ]]; then
    step "Writing ceph.conf into the bundle"
    [[ -f "$BUNDLE" ]] || die "Bundle not found: $BUNDLE  (use --bundle or --no-bundle)"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "  [dry-run] would write ceph-enabled / internal-ceph-enabled /"
        info "            trilio-ceph-username / ceph-conf into $BUNDLE"
    else
        cp -f "$BUNDLE" "${BUNDLE}.bak" || die "Could not back up $BUNDLE"
        write_bundle "$BUNDLE" "$CEPH_CONF" "$CLIENT" "$APP" \
            || die "Failed to update $BUNDLE (original kept at ${BUNDLE}.bak)"
        python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$BUNDLE" \
            || die "$BUNDLE is not valid YAML after the edit — restore ${BUNDLE}.bak"
        info "  updated $BUNDLE  (original at ${BUNDLE}.bak)"
    fi
fi

# If the application is already deployed, apply ceph-conf live too, so the
# bundle and the running app cannot drift.
if [[ $APP_DEPLOYED -eq 1 ]]; then
    step "Applying ceph.conf to the running application"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  [dry-run] juju config %s ceph-conf="$(cat %s)"\n' "$APP" "$CEPH_CONF"
    else
        juju config "${MODEL_ARG[@]}" "$APP" ceph-conf="$(cat "$CEPH_CONF")" \
            || die "Failed to set ceph-conf"
    fi
    info "  loaded $(wc -l < "$CEPH_CONF") lines"
fi

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
# "not authorised". Both the grant and the config need the application to
# exist, so they wait until after the deploy when it does not.
if [[ $APP_DEPLOYED -eq 1 ]]; then
    step "Granting the secret to $APP"
    run juju grant-secret "${MODEL_ARG[@]}" "$SECRET_NAME" "$APP" \
        || die "Failed to grant secret $SECRET_NAME to $APP"

    step "Pointing $APP at the secret"
    run juju config "${MODEL_ARG[@]}" "$APP" ceph-keyring="$SECRET_ID" \
        || die "Failed to set ceph-keyring"
fi

if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. Nothing was changed.\n'
    exit 0
fi

if [[ $APP_DEPLOYED -eq 0 ]]; then
    cat <<EOF

Bundle and secret are ready. '$APP' is not deployed yet, so the grant could not
be made — a secret cannot be granted to an application that does not exist.

Deploy, then run these two commands:

  juju deploy ${MODEL_ARG[*]:+${MODEL_ARG[*]} }./$(basename "$BUNDLE")

  juju grant-secret ${MODEL:+-m $MODEL }$SECRET_NAME $APP
  juju config ${MODEL:+-m $MODEL }$APP ceph-keyring=$SECRET_ID

Or simply re-run this script after the deploy — it is idempotent, and will then
take the grant and verification path.
EOF
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
