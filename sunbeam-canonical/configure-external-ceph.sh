#!/usr/bin/env bash
# configure-external-ceph.sh — wire trilio-data-mover to an EXTERNAL Ceph cluster.
#
# For a Ceph cluster deployed outside Sunbeam (cephadm, Rook, or other
# third-party tooling) that Cinder and/or Nova already use.
#
# RUN THIS BEFORE `juju deploy`. It prepares the deployment, nothing more:
#
#   1. validates the ceph.conf and keyring you pass in
#   2. writes ceph-enabled / internal-ceph-enabled / trilio-ceph-username and
#      the ceph.conf contents into the deployment bundle
#   3. stores the keyring in a Juju secret
#   4. prints the deploy and grant commands to run next
#
# ceph.conf goes in the bundle because it holds no secret and belongs under
# version control with the rest of the deployment. The keyring is a cephx
# credential and only ever goes into a Juju secret.
#
# It deliberately does NOT grant the secret. `juju grant-secret` requires the
# application to exist, so it cannot run before the deploy — and a script that
# behaves differently on its second run is harder to reason about than one
# clear boundary: prepare here, deploy and grant afterwards. The exact commands
# are printed at the end and are also in the install document.
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
#   --no-bundle          Do not touch any bundle; create the secret only.
#   --client <name>      Ceph client name. Default: read from the keyring's
#                        [client.X] stanza.
#   --app <name>         Juju application. Default: trilio-data-mover
#   --model <name>       Juju model. Default: current model
#   --secret-name <name> Juju secret label. Default: <app>-ceph-keyring
#   --dry-run            Print what would run, change nothing.
#
# Re-runnable: an existing secret is updated rather than recreated, which is
# also how you rotate the keyring later.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CEPH_CONF="" KEYRING="" CLIENT="" APP="trilio-data-mover"
MODEL="" SECRET_NAME="" DRY_RUN=0
BUNDLE="${SCRIPT_DIR}/trilio-dataplane-bundle-external-ceph.yaml"
USE_BUNDLE=1

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
        --dry-run)     DRY_RUN=1;      shift ;;
        -h|--help)     sed -n '2,45p' "$0"; exit 0 ;;
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

# juju is a strictly-confined snap, so it gets a PRIVATE /tmp namespace: a
# keyring under /tmp is readable by this script and invisible to `juju
# add-secret`, which fails with a bare "no such file or directory" on a file
# that plainly exists. Catch it here, before the bundle has been rewritten.
KEYRING_ABS="$(cd "$(dirname "$KEYRING")" && pwd)/$(basename "$KEYRING")"
case "$KEYRING_ABS" in
    /tmp/*|/var/tmp/*|/dev/shm/*)
        die "The keyring is under ${KEYRING_ABS%%/*}/tmp, which juju cannot read.
  juju is a strictly-confined snap and gets its own private /tmp, so
  'juju add-secret ... keyring#file=' fails there on a file that exists.
  Move it under your home directory and re-run:

    mv $KEYRING_ABS ~/" ;;
esac

info "  ceph.conf: $CEPH_CONF"
info "  keyring:   $KEYRING"
info "  juju app:  $APP${MODEL:+  (model $MODEL)}"

[[ -z "$SECRET_NAME" ]] && SECRET_NAME="${APP}-ceph-keyring"

# ---------------------------------------------------------------------------
# 2. ceph.conf and the Ceph flags into the bundle
#
# It holds no secret, so it belongs in the bundle where it is version-
# controlled alongside the rest of the deployment definition. The keyring does
# NOT — that goes into a Juju secret in step 3.
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

# ---------------------------------------------------------------------------
# 3. Keyring — a Juju secret, never plain config
#
# The keyring is a cephx credential. As a secret it stays out of the
# controller's config store, `juju config` output, and `juju export-bundle`.
# ---------------------------------------------------------------------------
step "Storing the keyring as a Juju secret"

# Look the secret up by NAME. `juju secrets --format=json` is no good for this:
# it reports a `label`, which for a user-created secret is null — the name you
# passed to add-secret is simply absent from that listing. `show-secret`
# resolves a name and does return it. It exits 0 with `{}` on a miss, so the
# empty output is the signal, not the exit code.
existing_id() {
    juju show-secret "${MODEL_ARG[@]}" "$SECRET_NAME" --format=json 2>/dev/null \
      | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for sid, s in (d or {}).items():
    if s.get('name') == '$SECRET_NAME':
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
        if [[ "$SECRET_ID" != secret:* ]]; then
            case "$SECRET_ID" in
                *"no such file or directory"*)
                    die "juju cannot read $KEYRING, although this script just did.
  juju is a strictly-confined snap: it can only read files it is permitted to
  see, which excludes /tmp and most paths outside your home directory. Copy the
  keyring under your home directory and re-run.

  juju said: $SECRET_ID" ;;
                *) die "add-secret did not return a secret URI. Output was: $SECRET_ID" ;;
            esac
        fi
    fi
fi
info "  secret id: $SECRET_ID"


if [[ $DRY_RUN -eq 1 ]]; then
    printf '\nDry run complete. Nothing was changed.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# 4. Hand off the commands that need live units
#
# The grant deliberately is NOT done here. `juju grant-secret` requires the
# application to exist, so it cannot run before the deploy — and this script's
# whole job is to prepare the bundle you are about to deploy. Printing the
# commands keeps one clear boundary (prepare here, deploy and grant there)
# instead of a script that behaves differently depending on whether it is being
# run for the first or the second time.
# ---------------------------------------------------------------------------
cat <<EOF

Bundle and secret are ready.

Deploy, then run these two commands — the grant is what lets the application
read the secret. Without it the charm reports the secret cannot be found, since
Juju does not distinguish "absent" from "you are not allowed to read it":

  juju deploy ${MODEL:+-m $MODEL }./$(basename "$BUNDLE")

  juju grant-secret ${MODEL:+-m $MODEL }$SECRET_NAME $APP
  juju config ${MODEL:+-m $MODEL }$APP ceph-keyring=$SECRET_ID

Then confirm the credential works, from a compute node. --id is required:
without it rbd authenticates as client.admin and proves nothing about this
client:

  juju ssh ${MODEL:+-m $MODEL }$APP/0 -- sudo rbd --id $CLIENT ls <cinder-pool>

A permission error means client.$CLIENT is missing rwx on that pool. Widen it
on a Ceph admin node:

  ceph auth caps client.$CLIENT \\
    mon 'allow r, allow command "osd blacklist", allow command "osd blocklist"' \\
    osd 'allow rwx pool=<cinder-pool>, allow rwx pool=<nova-pool>'
EOF
