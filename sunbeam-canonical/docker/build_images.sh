#!/usr/bin/env bash
# build_images.sh — Build TrilioVault OCI images for Sunbeam Canonical OpenStack
#
# WLM, DMAPI, DMS images: use a trilio.list APT repo substitution.
# Horizon plugin image: uses pip with TRILIO_PIP_INDEX_URL build arg.
#
# Usage:
#   bash build_images.sh --repo-url <APT_REPO_URL> [--pip-url <PIP_INDEX_URL>] \
#                        [--version <tag>] [--registry <r>] [--push]
#
# Options:
#   --repo-url   Full APT repo line for trilio.list (required for WLM/DMAPI/DMS), e.g.:
#                  "deb [trusted=yes] https://apt.fury.io/trilio-maint-6-2 /"
#   --pip-url    PyPI extra index URL for horizon plugin pip packages, e.g.:
#                  "https://pypi.fury.io/trilio/"
#   --version    Image tag suffix (default: 6.2.1-2024.1)
#   --registry   Registry prefix (default: docker.io/trilio)
#   --push       Push built images to registry after building
#
# Images built:
#   <registry>/trilio-wlm-canonical:<version>       (also used as DMS sidecar)
#   <registry>/trilio-datamover-api-canonical:<version>
#   <registry>/trilio-horizon-plugin-canonical:<version>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL=""
PIP_URL=""
VERSION="6.2.1-2024.1"
REGISTRY="docker.io/trilio"
PUSH=false

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 --repo-url <APT_REPO_URL> [OPTIONS]

  --repo-url   Full APT repo line for trilio.list (required)
  --version    Image tag (default: $VERSION)
  --registry   Registry prefix (default: $REGISTRY)
  --push       Push images after building
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --repo-url)  REPO_URL="$2";  shift 2 ;;
        --version)   VERSION="$2";   shift 2 ;;
        --registry)  REGISTRY="$2";  shift 2 ;;
        --push)      PUSH=true;      shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -n "$REPO_URL" ]] || { usage >&2; die "--repo-url is required"; }

declare -A IMAGES=(
    [trilio-wlm-canonical]="$SCRIPT_DIR/trilio-wlm"
    [trilio-datamover-api-canonical]="$SCRIPT_DIR/trilio-datamover-api"
)

for name in "${!IMAGES[@]}"; do
    ctx="${IMAGES[$name]}"
    tag="$REGISTRY/$name:$VERSION"
    list_template="$ctx/trilio.list"
    list_real="$ctx/trilio.list.real"

    log "Building $tag ..."

    # Substitute placeholder with real APT repo URL
    sed "s|{DEB_REPO_URL}|${REPO_URL}|g" "$list_template" > "$list_real"
    # Dockerfile ADDs trilio.list — temporarily replace it
    cp "$list_template" "$list_template.bak"
    cp "$list_real" "$list_template"

    docker build -t "$tag" "$ctx" || {
        cp "$list_template.bak" "$list_template"
        rm -f "$list_template.bak" "$list_real"
        die "docker build failed for $name"
    }

    # Restore template
    cp "$list_template.bak" "$list_template"
    rm -f "$list_template.bak" "$list_real"

    log "Built $tag"

    if $PUSH; then
        log "Pushing $tag ..."
        docker push "$tag"
        log "Pushed $tag"
    fi
done

log "Done. Version: $VERSION"
