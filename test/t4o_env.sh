#!/usr/bin/env bash
# t4o_env.sh — shared library for the T4O functional test suite.
#
# Source this at the top of each numbered script:
#   source "$(dirname "$0")/t4o_env.sh"
#
# Every step of the test is identical across OpenStack distros EXCEPT how you
# reach the WLM service and the DataMover nodes. That difference lives here and
# nowhere else: the numbered scripts call the helpers below and never invoke
# kubectl/oc/docker/podman/juju directly.
#
# Nothing here creates or modifies anything. Sourcing this file is pure
# discovery — detection, credential lookup, and helper definitions.
#
# Environment knobs:
#   T4O_DISTRO       skip detection and force an adapter
#                    (kolla|rhoso18|rhosp17|canonical|sunbeam|openstack-helm)
#   T4O_BT_SCOPE     which backup targets to exercise: s3 | nfs | both
#   TRILIO_ENV_DIR   directory holding backup_targets.yaml / license_trilio.txt
#                    (default: <two levels up from this file>/env)
#   T4O_WORK_DIR     scratch dir for openrc / resources.env (default ~/t4o-test)

# Guard against double-sourcing — several scripts may source this in one run.
[[ -n "${_T4O_ENV_SOURCED:-}" ]] && return 0
_T4O_ENV_SOURCED=1

_T4O_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# test/ sits one level below the repo root, and env/ is a sibling of the repo,
# so the workspace root is two levels up. This was three when these scripts
# lived under sunbeam-canonical/test/ — a flat clone made the old walk resolve
# to /home and report a missing file rather than a bad path.
export T4O_WORKSPACE_ROOT="${T4O_WORKSPACE_ROOT:-$(cd "$_T4O_LIB_DIR/../.." && pwd)}"
export TRILIO_ENV_DIR="${TRILIO_ENV_DIR:-${T4O_WORKSPACE_ROOT}/env}"
export T4O_WORK_DIR="${T4O_WORK_DIR:-$HOME/t4o-test}"
export T4O_OPENRC="${T4O_WORK_DIR}/openrc"
export T4O_RESOURCES_FILE="${T4O_WORK_DIR}/resources.env"
mkdir -p "$T4O_WORK_DIR"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
t4o_info()  { printf '%s\n' "$*"; }
t4o_warn()  { printf 'WARN: %s\n' "$*" >&2; }
t4o_error() { printf 'ERROR: %s\n' "$*" >&2; }
t4o_die()   { t4o_error "$*"; exit 1; }

# The openstack CLI on some setups prints plugin-load noise on every call
# (e.g. "Could not load 'workloadmgr_dms_*': No module named 'kombu'").
# It is cosmetic, but it corrupts any output we parse — strip it everywhere.
t4o_denoise() { grep -vE "Could not load '|No module named|^$" || true; }

# ---------------------------------------------------------------------------
# Distro detection
#
# Probes run cheapest-and-most-specific first. The first hit wins. Each probe
# must be read-only and must not fail the script when the tool is absent.
# ---------------------------------------------------------------------------
_have() { command -v "$1" >/dev/null 2>&1; }

detect_distro() {
    if [[ -n "${T4O_DISTRO:-}" ]]; then
        t4o_info "Distro forced via T4O_DISTRO: $T4O_DISTRO"
        return 0
    fi

    if _have oc && oc get tvocontrolplane -n trilio-openstack >/dev/null 2>&1; then
        T4O_DISTRO=rhoso18
    elif _have juju && juju status --format=json 2>/dev/null | grep -q '"trilio-wlm-k8s"'; then
        T4O_DISTRO=sunbeam
    elif _have juju && juju status --format=json 2>/dev/null | grep -q '"trilio-wlm"'; then
        T4O_DISTRO=canonical
    elif _have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^triliovault_wlm_api$'; then
        T4O_DISTRO=kolla
    elif _have kubectl && kubectl get pods -A 2>/dev/null | grep -qE 'trilio.*wlm-api'; then
        T4O_DISTRO=openstack-helm
    elif _have podman && podman ps --format '{{.Names}}' 2>/dev/null | grep -q 'triliovault_wlm_api'; then
        T4O_DISTRO=rhosp17
    else
        t4o_die "Could not detect a T4O deployment on this host.
  Probed for: RHOSO18 (oc/tvocontrolplane), Sunbeam and Canonical (juju),
  kolla (docker), OpenStack-Helm (kubectl), RHOSP17 (podman).
  If T4O is not deployed, deploy it first — this suite tests an existing
  install and never deploys one. Override detection with T4O_DISTRO=<name>."
    fi
    export T4O_DISTRO
    t4o_info "Detected distro: $T4O_DISTRO"
}

# ---------------------------------------------------------------------------
# Per-distro constants
#
# Set once, after detection, so the helpers below stay short.
# ---------------------------------------------------------------------------
_t4o_set_distro_constants() {
    case "$T4O_DISTRO" in
      sunbeam)
        WLM_POD="${WLM_POD:-trilio-wlm-k8s-0}"
        WLM_CONTAINER="${WLM_CONTAINER:-trilio-wlm}"
        K8S_NAMESPACE="${K8S_NAMESPACE:-openstack}"
        # Sunbeam's Juju models are controller-qualified; a bare "-m openstack"
        # fails with "model admin/openstack not found".
        T4O_JUJU_K8S_MODEL="${T4O_JUJU_K8S_MODEL:-controller0/openstack}"
        T4O_JUJU_MACHINE_MODEL="${T4O_JUJU_MACHINE_MODEL:-openstack-machines}"
        T4O_DM_APP="${T4O_DM_APP:-trilio-data-mover}"
        # Sunbeam's Keystone is HTTPS with a self-signed CA.
        T4O_OS_INSECURE="--insecure"
        ;;
      openstack-helm)
        K8S_NAMESPACE="${K8S_NAMESPACE:-trilio-openstack}"
        WLM_DEPLOY="${WLM_DEPLOY:-deploy/triliovault-wlm-api}"
        T4O_OS_INSECURE=""
        ;;
      rhoso18)
        K8S_NAMESPACE="${K8S_NAMESPACE:-trilio-openstack}"
        WLM_DEPLOY="${WLM_DEPLOY:-deploy/triliovault-wlm-api}"
        # EDPM names its podman containers with hyphens, unlike kolla/rhosp17's
        # underscores. Without this DM_CTR was empty on rhoso18 and every
        # dm_shell/dm_logs call ran `podman exec  <cmd>` with no container.
        DM_CTR="${DM_CTR:-triliovault-datamover}"
        T4O_OS_INSECURE=""
        ;;
      kolla|rhosp17)
        WLM_CTR="${WLM_CTR:-triliovault_wlm_api}"
        DM_CTR="${DM_CTR:-triliovault_datamover}"
        T4O_OS_INSECURE=""
        ;;
      canonical)
        T4O_DM_APP="${T4O_DM_APP:-trilio-data-mover}"
        T4O_OS_INSECURE="--insecure"
        ;;
    esac
    export WLM_POD WLM_CONTAINER K8S_NAMESPACE WLM_DEPLOY WLM_CTR DM_CTR \
           T4O_JUJU_K8S_MODEL T4O_JUJU_MACHINE_MODEL T4O_DM_APP T4O_OS_INSECURE
}

# ---------------------------------------------------------------------------
# wlm_shell — run an arbitrary shell command inside the WLM service
#
# Used by the reachability gate, which must probe FROM the component that will
# actually talk to the backup target, not from the bastion.
# ---------------------------------------------------------------------------
wlm_shell() {
    case "$T4O_DISTRO" in
      sunbeam)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- bash -lc "$*" ;;
      openstack-helm)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_DEPLOY" -- bash -lc "$*" ;;
      rhoso18)
        oc -n "$K8S_NAMESPACE" exec "$WLM_DEPLOY" -- bash -lc "$*" ;;
      kolla)
        docker exec "$WLM_CTR" bash -lc "$*" ;;
      rhosp17)
        sudo podman exec "$WLM_CTR" bash -lc "$*" ;;
      canonical)
        juju ssh trilio-wlm/leader -- "$*" ;;
      *) t4o_die "wlm_shell: unsupported distro '$T4O_DISTRO'" ;;
    esac
}

# ---------------------------------------------------------------------------
# wlm_exec — run `workloadmgr <args>` inside the WLM service
#
# workloadmgr MUST run inside the WLM service: the python3-workloadmgrclient
# plugin ships only in the WLM image, never on a bastion or build host.
#
# The `setsid` prefix is Sunbeam-only. Pebble (container PID 1) hands the
# process a controlling terminal, and workloadmgr's cliff/cmd2 layer then opens
# /dev/tty and calls curses.cbreak(), which fails with "cbreak() returned ERR".
# setsid detaches from the terminal so cmd2 skips curses init. Applying it on
# other distros would be harmless but would obscure why it exists here.
# ---------------------------------------------------------------------------
_t4o_os_env_args() {
    printf '%s ' \
      "OS_AUTH_URL=$OS_AUTH_URL" \
      "OS_USERNAME=$OS_USERNAME" \
      "OS_PASSWORD=$OS_PASSWORD" \
      "OS_PROJECT_NAME=$OS_PROJECT_NAME" \
      "OS_USER_DOMAIN_NAME=$OS_USER_DOMAIN_NAME" \
      "OS_PROJECT_DOMAIN_NAME=$OS_PROJECT_DOMAIN_NAME" \
      "OS_IDENTITY_API_VERSION=$OS_IDENTITY_API_VERSION"
}

wlm_exec() {
    case "$T4O_DISTRO" in
      sunbeam)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
          env $(_t4o_os_env_args) setsid workloadmgr "$@" ;;
      openstack-helm)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_DEPLOY" -- \
          env $(_t4o_os_env_args) workloadmgr "$@" ;;
      rhoso18)
        oc -n "$K8S_NAMESPACE" exec "$WLM_DEPLOY" -- \
          env $(_t4o_os_env_args) workloadmgr "$@" ;;
      kolla)
        docker exec $(printf -- '-e %s ' $(_t4o_os_env_args)) "$WLM_CTR" workloadmgr "$@" ;;
      rhosp17)
        sudo podman exec $(printf -- '-e %s ' $(_t4o_os_env_args)) "$WLM_CTR" workloadmgr "$@" ;;
      canonical)
        juju ssh trilio-wlm/leader -- "env $(_t4o_os_env_args) workloadmgr $*" ;;
      *) t4o_die "wlm_exec: unsupported distro '$T4O_DISTRO'" ;;
    esac
}

# ---------------------------------------------------------------------------
# RHOSO 18 lives in two namespaces: T4O in K8S_NAMESPACE (trilio-openstack) and
# OpenStack itself — including the openstackclient pod that carries the only
# openstack CLI on the cluster — in T4O_OS_NAMESPACE (openstack).
# ---------------------------------------------------------------------------
export T4O_OS_NAMESPACE="${T4O_OS_NAMESPACE:-openstack}"

# ---------------------------------------------------------------------------
# os_exec — run `openstack <args>` from wherever the CLI is available
#
# Unlike workloadmgr, the openstack CLI is usually present on the host we are
# already on. Falls back to running inside the WLM service if it is not.
# ---------------------------------------------------------------------------
os_exec() {
    if _have openstack; then
        openstack $T4O_OS_INSECURE "$@" 2> >(t4o_denoise >&2)
    else
        wlm_exec_raw_openstack "$@"
    fi
}

wlm_exec_raw_openstack() {
    case "$T4O_DISTRO" in
      sunbeam)
        kubectl exec -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" -- \
          env $(_t4o_os_env_args) openstack $T4O_OS_INSECURE "$@" ;;
      rhoso18)
        # RHOSO ships the openstackclient pod with credentials already in its
        # environment, so no _t4o_os_env_args here. `exec --` (not `rsh`) so argv
        # is passed through verbatim - rsh wraps the command in `sh -c` and would
        # word-split arguments such as --property 'a=b c'.
        oc exec -n "$T4O_OS_NAMESPACE" openstackclient -- \
          openstack $T4O_OS_INSECURE "$@" ;;
      *) t4o_die "os_exec: no openstack CLI on this host and no in-service fallback for '$T4O_DISTRO'" ;;
    esac
}

# ---------------------------------------------------------------------------
# wlm_conf / wlm_logs — read the live WLM config and logs
#
# The config path is /etc/triliovault-wlm/triliovault-wlm.conf on EVERY distro.
# It is never named workloadmgr.conf. Only the way in differs.
# ---------------------------------------------------------------------------
export T4O_WLM_CONF="/etc/triliovault-wlm/triliovault-wlm.conf"

wlm_conf() {
    if [[ -n "${1:-}" ]]; then
        # Return the value of one key. Tolerates "key = value" and "key=value".
        wlm_shell "grep -E '^[[:space:]]*$1[[:space:]]*=' $T4O_WLM_CONF" 2>/dev/null \
          | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r'
    else
        wlm_shell "cat $T4O_WLM_CONF"
    fi
}

wlm_logs() {
    local lines="${1:-100}"
    case "$T4O_DISTRO" in
      sunbeam)        kubectl logs -n "$K8S_NAMESPACE" "$WLM_POD" -c "$WLM_CONTAINER" --tail="$lines" ;;
      openstack-helm) kubectl logs -n "$K8S_NAMESPACE" "$WLM_DEPLOY" --tail="$lines" ;;
      rhoso18)        oc -n "$K8S_NAMESPACE" logs "$WLM_DEPLOY" --tail="$lines" ;;
      kolla)          docker logs --tail "$lines" "$WLM_CTR" ;;
      rhosp17)        sudo podman logs --tail "$lines" "$WLM_CTR" ;;
      canonical)      juju ssh trilio-wlm/leader -- "sudo tail -n $lines /var/log/triliovault/*.log" ;;
    esac 2>&1
}

# ---------------------------------------------------------------------------
# DataMover access
#
# dm_hosts prints one opaque HANDLE per DataMover node. What a handle IS depends
# on the distro — a Juju unit name on Sunbeam/Canonical, a compute hostname
# elsewhere — and only dm_shell/dm_logs need to know. Callers just iterate.
# ---------------------------------------------------------------------------
dm_hosts() {
    case "$T4O_DISTRO" in
      sunbeam|canonical)
        local model_arg=""
        [[ -n "${T4O_JUJU_MACHINE_MODEL:-}" ]] && model_arg="-m $T4O_JUJU_MACHINE_MODEL"
        juju status $model_arg --format=json 2>/dev/null \
          | python3 -c "
import json,sys
d=json.load(sys.stdin)
app=d.get('applications',{}).get('$T4O_DM_APP',{})
for u in sorted(app.get('units',{})):
    print(u)
    # subordinates are nested under their principal
for pname,p in sorted(d.get('applications',{}).items()):
    for uname,u in sorted(p.get('units',{}).items()):
        for s in sorted(u.get('subordinates',{}) or {}):
            if s.startswith('$T4O_DM_APP/'):
                print(s)
" 2>/dev/null | sort -u
        ;;
      *)
        # Compute nodes running nova-compute; the DataMover is co-located.
        os_exec compute service list --service nova-compute -f value -c Host 2>/dev/null \
          | t4o_denoise | sort -u
        ;;
    esac
}

# ---------------------------------------------------------------------------
# RHOSO 18 DataMover access
#
# dm_hosts yields nova-compute hostnames, but on RHOSO those are usually absent
# from the bastion's DNS and the EDPM nodes do not trust the bastion's own SSH
# key. Both are solved from the cluster: the OpenStackDataPlaneNodeSet records a
# routable ansibleHost per node, and the dataplane ansible key is in a Secret.
# cloud-admin exists on EDPM nodes but is not authorised for podman, so the
# default user is root.
# ---------------------------------------------------------------------------
export T4O_EDPM_SSH_SECRET="${T4O_EDPM_SSH_SECRET:-dataplane-ansible-ssh-private-key-secret}"
export T4O_DM_SSH_USER="${T4O_DM_SSH_USER:-root}"

_t4o_edpm_key() {
    local key="$T4O_WORK_DIR/edpm_ssh_key"
    if [[ ! -s "$key" ]]; then
        mkdir -p "$T4O_WORK_DIR"
        oc get secret -n "$T4O_OS_NAMESPACE" "$T4O_EDPM_SSH_SECRET" \
            -o jsonpath='{.data.ssh-privatekey}' 2>/dev/null | base64 -d > "$key" 2>/dev/null
        chmod 600 "$key" 2>/dev/null
    fi
    [[ -s "$key" ]] || {
        t4o_error "_t4o_edpm_key: cannot read secret '$T4O_EDPM_SSH_SECRET' in namespace '$T4O_OS_NAMESPACE'"
        return 1
    }
    printf '%s' "$key"
}

_t4o_edpm_addr() {
    local short="${1%%.*}" ip
    ip=$(oc get openstackdataplanenodeset -n "$T4O_OS_NAMESPACE" -o json 2>/dev/null \
      | python3 -c "
import json,sys
short=sys.argv[1]
for item in json.load(sys.stdin).get('items',[]):
    for name,node in (item.get('spec',{}).get('nodes') or {}).items():
        if short in (name, node.get('hostName')):
            addr=(node.get('ansible') or {}).get('ansibleHost')
            if addr:
                print(addr)
                raise SystemExit
" "$short" 2>/dev/null)
    # Fall back to the name we were given: on a cloud where DNS does resolve, it works.
    printf '%s' "${ip:-$1}"
}

_t4o_edpm_ssh() {
    local host="$1"; shift
    local key
    key=$(_t4o_edpm_key) || return 1
    ssh -i "$key" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
        "${T4O_DM_SSH_USER}@$(_t4o_edpm_addr "$host")" "$@" < /dev/null
}

dm_shell() {
    local host="$1"; shift
    case "$T4O_DISTRO" in
      sunbeam|canonical)
        local model_arg=""
        [[ -n "${T4O_JUJU_MACHINE_MODEL:-}" ]] && model_arg="-m $T4O_JUJU_MACHINE_MODEL"
        # DataMover is a machine subordinate — it runs on the host, not in a
        # container, so there is no exec wrapper here.
        juju ssh $model_arg --pty=false "$host" -- "$*" < /dev/null ;;
      kolla)
        ssh -o StrictHostKeyChecking=no "$host" "docker exec $DM_CTR bash -lc '$*'" < /dev/null ;;
      rhoso18)
        # Ship the command base64-encoded and decode it on the node. Callers pass
        # commands that contain single quotes - 01_check_backup_targets.sh sends
        # curl -w 'CODE:%{http_code}' and printf '|RC:%s' - and the `bash -lc '$*'`
        # form used by the other branches lets those quotes close the wrapper
        # early, so the node ran a fragment as its own command
        # ("RC:%s $?: command not found"). The encoded string contains no quotes
        # at all, so nothing can be re-split on the way through ssh.
        _t4o_edpm_ssh "$host" \
          "echo $(printf '%s' "$*" | base64 | tr -d '\n') | base64 -d | sudo podman exec -i $DM_CTR bash -l" ;;
      rhosp17)
        # Same nested-quoting weakness as above; left as-is because it cannot be
        # exercised from here. Mirror the rhoso18 branch when a RHOSP 17 setup is
        # available to test against.
        ssh -o StrictHostKeyChecking=no "$host" "sudo podman exec $DM_CTR bash -lc '$*'" < /dev/null ;;
      openstack-helm)
        local pod
        pod=$(kubectl get pods -n "$K8S_NAMESPACE" --field-selector "spec.nodeName=$host" \
                -o jsonpath='{.items[?(@.metadata.labels.application=="triliovault-datamover")].metadata.name}' 2>/dev/null | awk '{print $1}')
        [[ -z "$pod" ]] && { t4o_error "dm_shell: no datamover pod on node $host"; return 1; }
        kubectl exec -n "$K8S_NAMESPACE" "$pod" -- bash -lc "$*" ;;
      *) t4o_die "dm_shell: unsupported distro '$T4O_DISTRO'" ;;
    esac
}

dm_logs() {
    local host="$1" lines="${2:-100}"
    case "$T4O_DISTRO" in
      sunbeam|canonical)
        dm_shell "$host" "sudo journalctl -u triliovault-datamover -n $lines --no-pager" ;;
      kolla)
        ssh -o StrictHostKeyChecking=no "$host" "docker logs --tail $lines $DM_CTR" < /dev/null ;;
      rhoso18)
        _t4o_edpm_ssh "$host" "sudo podman logs --tail $lines $DM_CTR" ;;
      rhosp17)
        ssh -o StrictHostKeyChecking=no "$host" "sudo podman logs --tail $lines $DM_CTR" < /dev/null ;;
      openstack-helm)
        dm_shell "$host" "tail -n $lines /var/log/triliovault/triliovault-datamover.log" ;;
    esac 2>&1
}

# ---------------------------------------------------------------------------
# copy_to_wlm — place a local file inside the WLM service
#
# Used for the licence file, and for CA certs during backup-target creation.
# ---------------------------------------------------------------------------
copy_to_wlm() {
    local src="$1" dst="$2"
    [[ -f "$src" ]] || t4o_die "copy_to_wlm: source file not found: $src"
    case "$T4O_DISTRO" in
      sunbeam)        kubectl cp "$src" "$K8S_NAMESPACE/$WLM_POD:$dst" -c "$WLM_CONTAINER" ;;
      openstack-helm) kubectl cp "$src" "$K8S_NAMESPACE/$(_t4o_first_pod):$dst" ;;
      rhoso18)        oc -n "$K8S_NAMESPACE" cp "$src" "$(_t4o_first_pod):$dst" ;;
      kolla)          docker cp "$src" "$WLM_CTR:$dst" ;;
      rhosp17)        sudo podman cp "$src" "$WLM_CTR:$dst" ;;
      canonical)      juju scp "$src" "trilio-wlm/leader:$dst" ;;
      *) t4o_die "copy_to_wlm: unsupported distro '$T4O_DISTRO'" ;;
    esac
}

_t4o_first_pod() {
    case "$T4O_DISTRO" in
      # The label is service=triliovault-wlm (the whole WLM service); the
      # per-microservice discriminator is component=wlm-api. There is no
      # service=triliovault-wlm-api label, so that selector matched nothing and
      # the jsonpath died with "array index out of bounds", leaving copy_to_wlm
      # to run `oc cp` against an empty pod name.
      rhoso18)  oc -n "$K8S_NAMESPACE" get pods -l application=triliovault,component=wlm-api -o jsonpath='{.items[0].metadata.name}' ;;
      *)        kubectl get pods -n "$K8S_NAMESPACE" -l application=triliovault-wlm -o jsonpath='{.items[0].metadata.name}' ;;
    esac
}

# ---------------------------------------------------------------------------
# Cloud admin credential discovery
#
# Preference order per distro is documented in the Confluence companion page
# "Cloud Admin Credentials — Storage, Lifecycle and Retrieval per Distro".
# Short version: nothing is ever deleted except on the two Canonical distros,
# which never persist the password at all and must be asked for it live.
#
# The password is never printed. Only which discovery path succeeded is logged.
# ---------------------------------------------------------------------------
discover_cloud_admin() {
    OS_IDENTITY_API_VERSION=3
    local via=""

    case "$T4O_DISTRO" in
      sunbeam)
        OS_PASSWORD=$(juju run keystone/leader get-admin-account \
                        -m "$T4O_JUJU_K8S_MODEL" 2>/dev/null \
                      | grep '^password:' | awk '{print $2}')
        # NOT get-admin-password — that action does not exist on keystone-k8s.
        OS_USERNAME=admin; OS_PROJECT_NAME=admin
        OS_USER_DOMAIN_NAME=admin_domain; OS_PROJECT_DOMAIN_NAME=admin_domain
        via="juju action keystone/leader get-admin-account"
        ;;
      canonical)
        OS_PASSWORD=$(juju exec --unit keystone/leader -- leader-get admin_passwd 2>/dev/null | tr -d '\r')
        [[ -z "$OS_PASSWORD" ]] && OS_PASSWORD=$(juju config keystone admin-password 2>/dev/null | tr -d '\r')
        OS_USERNAME=admin; OS_PROJECT_NAME=admin
        OS_USER_DOMAIN_NAME=admin_domain; OS_PROJECT_DOMAIN_NAME=admin_domain
        via="juju leader-get admin_passwd"
        ;;
      kolla)
        # Trilio writes its own cloud admin rc; fall back to kolla's.
        for rc in /etc/kolla/triliovault-cloudrc /etc/kolla/admin-openrc.sh; do
            if [[ -r "$rc" ]]; then
                # shellcheck disable=SC1090
                source "$rc"; via="$rc"; break
            fi
        done
        ;;
      rhosp17)
        for rc in /var/lib/config-data/puppet-generated/triliovaultwlmapi/etc/triliovault-wlm/cloud_admin_rc \
                  "$HOME/overcloudrc"; do
            if sudo test -r "$rc" 2>/dev/null || [[ -r "$rc" ]]; then
                # shellcheck disable=SC1090
                source <(sudo cat "$rc" 2>/dev/null || cat "$rc"); via="$rc"; break
            fi
        done
        ;;
      rhoso18)
        OS_PASSWORD=$(oc -n trilio-openstack get secret openstack-secret \
                        -o jsonpath='{.data.CloudAdminPassword}' 2>/dev/null | base64 -d)
        [[ -z "$OS_PASSWORD" ]] && OS_PASSWORD=$(oc -n openstack get secret openstack-secret \
                        -o jsonpath='{.data.CloudAdminPassword}' 2>/dev/null | base64 -d)
        OS_USERNAME=admin; OS_PROJECT_NAME=admin
        OS_USER_DOMAIN_NAME=Default; OS_PROJECT_DOMAIN_NAME=Default
        via="oc secret openstack-secret/CloudAdminPassword"
        ;;
      openstack-helm)
        local s=triliovault-keystone-admin
        OS_PASSWORD=$(kubectl get secret "$s" -n "$K8S_NAMESPACE" -o jsonpath='{.data.OS_PASSWORD}' 2>/dev/null | base64 -d)
        OS_USERNAME=$(kubectl get secret "$s" -n "$K8S_NAMESPACE" -o jsonpath='{.data.OS_USERNAME}' 2>/dev/null | base64 -d)
        OS_PROJECT_NAME=$(kubectl get secret "$s" -n "$K8S_NAMESPACE" -o jsonpath='{.data.OS_PROJECT_NAME}' 2>/dev/null | base64 -d)
        OS_USER_DOMAIN_NAME=$(kubectl get secret "$s" -n "$K8S_NAMESPACE" -o jsonpath='{.data.OS_USER_DOMAIN_NAME}' 2>/dev/null | base64 -d)
        OS_PROJECT_DOMAIN_NAME=$(kubectl get secret "$s" -n "$K8S_NAMESPACE" -o jsonpath='{.data.OS_PROJECT_DOMAIN_NAME}' 2>/dev/null | base64 -d)
        via="k8s secret $s"
        ;;
    esac

    # auth_url always comes from the live WLM config — that is the value the
    # service itself uses, so it cannot drift from what we authenticate against.
    local conf_auth_url
    conf_auth_url=$(wlm_conf auth_url)
    if [[ -n "$conf_auth_url" ]]; then
        if [[ -n "${OS_AUTH_URL:-}" && "$OS_AUTH_URL" != "$conf_auth_url" ]]; then
            t4o_warn "auth_url differs: rc says '$OS_AUTH_URL', WLM conf says '$conf_auth_url'. Using the WLM conf value."
        fi
        OS_AUTH_URL="$conf_auth_url"
    fi

    [[ -n "${OS_AUTH_URL:-}"  ]] || t4o_die "Could not determine OS_AUTH_URL. Is T4O deployed and the WLM service running?"
    [[ -n "${OS_PASSWORD:-}"  ]] || t4o_die "Could not discover the cloud admin password for '$T4O_DISTRO' (tried: ${via:-none})."
    : "${OS_USERNAME:=admin}" "${OS_PROJECT_NAME:=admin}"
    : "${OS_USER_DOMAIN_NAME:=Default}" "${OS_PROJECT_DOMAIN_NAME:=Default}"

    export OS_AUTH_URL OS_PASSWORD OS_USERNAME OS_PROJECT_NAME \
           OS_USER_DOMAIN_NAME OS_PROJECT_DOMAIN_NAME OS_IDENTITY_API_VERSION

    # Written for the operator's convenience and for standalone re-runs.
    # 0600, and removed by 08_cleanup.sh — this suite does not add another
    # place where a cloud admin credential persists.
    umask 077
    cat > "$T4O_OPENRC" <<EOF
export OS_AUTH_URL='$OS_AUTH_URL'
export OS_USERNAME='$OS_USERNAME'
export OS_PASSWORD='$OS_PASSWORD'
export OS_PROJECT_NAME='$OS_PROJECT_NAME'
export OS_USER_DOMAIN_NAME='$OS_USER_DOMAIN_NAME'
export OS_PROJECT_DOMAIN_NAME='$OS_PROJECT_DOMAIN_NAME'
export OS_IDENTITY_API_VERSION='3'
EOF
    chmod 600 "$T4O_OPENRC"

    t4o_info "Cloud admin credentials discovered via: ${via:-<rc file>}"
    t4o_info "  OS_AUTH_URL=$OS_AUTH_URL  user=$OS_USERNAME  project=$OS_PROJECT_NAME  domain=$OS_USER_DOMAIN_NAME"
}

# Fail in seconds on a bad credential rather than twenty minutes into a backup.
verify_cloud_admin() {
    if os_exec token issue -f value -c id >/dev/null 2>&1; then
        t4o_info "Cloud admin credentials verified (token issued)."
    else
        t4o_die "Cloud admin credentials did not authenticate against $OS_AUTH_URL."
    fi
}

# ---------------------------------------------------------------------------
# Backup target scope
# ---------------------------------------------------------------------------
# s3 | nfs | both — the single switch every later step reads.
export T4O_BT_SCOPE="${T4O_BT_SCOPE:-both}"

t4o_scope_includes() {
    case "$T4O_BT_SCOPE" in
      both) return 0 ;;
      s3)   [[ "$1" == "s3"  ]] ;;
      nfs)  [[ "$1" == "nfs" ]] ;;
      *)    t4o_die "Invalid T4O_BT_SCOPE '$T4O_BT_SCOPE' (expected: s3, nfs, or both)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Backup target definitions
#
# Loaded from $TRILIO_ENV_DIR/backup_targets.yaml (top-level key
# `triliovault_backup_targets`). Credentials are never echoed.
#
# Exactly ONE S3 entry and ONE NFS entry are selected per run:
#   S3  — the entry flagged is_default, else the first s3 entry.
#   NFS — the first nfs entry.
# Override either by name with T4O_S3_TARGET / T4O_NFS_TARGET. That is what the
# reachability gate's "use a different backup target" option sets when the
# chosen one turns out to be unreachable.
# ---------------------------------------------------------------------------
t4o_backup_targets_file() { echo "${TRILIO_ENV_DIR}/backup_targets.yaml"; }

# List the names of entries of a given type — used to offer alternatives.
t4o_list_targets() {
    local want="$1" f; f="$(t4o_backup_targets_file)"
    [[ -f "$f" ]] || return 1
    python3 - "$f" "$want" <<'PYEOF'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
want = sys.argv[2]
for t in cfg.get('triliovault_backup_targets', []) or []:
    if (t.get('backup_target_type') or '').lower() == want:
        print(t.get('backup_target_name', ''))
PYEOF
}

t4o_load_backup_targets() {
    local f; f="$(t4o_backup_targets_file)"
    [[ -f "$f" ]] || t4o_die "Backup target definitions not found: $f
  Set TRILIO_ENV_DIR to the directory holding backup_targets.yaml."

    local tmp; tmp=$(mktemp /tmp/t4o-bt-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    python3 - "$f" "${T4O_S3_TARGET:-}" "${T4O_NFS_TARGET:-}" > "$tmp" <<'PYEOF'
import sys, yaml

cfg = yaml.safe_load(open(sys.argv[1])) or {}
want_s3, want_nfs = (sys.argv[2] or None), (sys.argv[3] or None)
targets = cfg.get('triliovault_backup_targets', []) or []

def pick(kind, wanted):
    cands = [t for t in targets if (t.get('backup_target_type') or '').lower() == kind]
    if wanted:
        for t in cands:
            if t.get('backup_target_name') == wanted:
                return t
        sys.exit(f"ERROR: no {kind} backup target named '{wanted}' in backup_targets.yaml")
    for t in cands:                      # prefer the default-flagged entry
        if t.get('is_default'):
            return t
    return cands[0] if cands else None

def sh(name, val):
    print("%s='%s'" % (name, str('' if val is None else val).replace("'", "'\\''")))

s3, nfs = pick('s3', want_s3), pick('nfs', want_nfs)

sh('BT_S3_PRESENT', 'yes' if s3 else '')
if s3:
    sh('BT_S3_NAME',         s3.get('backup_target_name', 'BT_S3'))
    sh('BT_S3_ENDPOINT',     s3.get('s3_endpoint_url', ''))
    sh('BT_S3_BUCKET',       s3.get('s3_bucket', ''))
    sh('BT_S3_REGION',       s3.get('s3_region_name', 'us-east-1'))
    sh('BT_S3_AUTH_VERSION', s3.get('s3_auth_version', 'DEFAULT'))
    sh('BT_S3_SIG_VERSION',  s3.get('s3_signature_version', 'default'))
    sh('BT_S3_SSL',          'true' if s3.get('s3_ssl_enabled', True) else 'false')
    sh('BT_S3_SSL_VERIFY',   'true' if s3.get('s3_ssl_verify', True) else 'false')
    sh('BT_S3_ACCESS_KEY',   s3.get('s3_access_key', ''))
    sh('BT_S3_SECRET_KEY',   s3.get('s3_secret_key', ''))
    sh('BT_S3_IS_DEFAULT',   'true' if s3.get('is_default', False) else 'false')
    ca = (s3.get('s3_ssl_ca_cert') or '').strip()
    ca_file = ''
    if ca:
        ca_file = '/tmp/t4o-s3-ca.pem'
        with open(ca_file, 'w') as fh:
            fh.write(ca + '\n')
    sh('BT_S3_CA_CERT_FILE', ca_file)

sh('BT_NFS_PRESENT', 'yes' if nfs else '')
if nfs:
    sh('BT_NFS_NAME',       nfs.get('backup_target_name', 'BT_NFS'))
    sh('BT_NFS_EXPORT',     nfs.get('nfs_server_export', ''))
    sh('BT_NFS_MOUNT_OPTS', nfs.get('nfs_mount_opts', ''))
PYEOF
    [[ ${PIPESTATUS[0]:-0} -eq 0 ]] || true
    grep -q '^ERROR:' "$tmp" && t4o_die "$(cat "$tmp")"

    # shellcheck disable=SC1090
    source "$tmp"

    export BT_S3_PRESENT BT_S3_NAME BT_S3_ENDPOINT BT_S3_BUCKET BT_S3_REGION \
           BT_S3_AUTH_VERSION BT_S3_SIG_VERSION BT_S3_SSL BT_S3_SSL_VERIFY \
           BT_S3_ACCESS_KEY BT_S3_SECRET_KEY BT_S3_IS_DEFAULT BT_S3_CA_CERT_FILE \
           BT_NFS_PRESENT BT_NFS_NAME BT_NFS_EXPORT BT_NFS_MOUNT_OPTS

    # A scope naming a type with no definition is a setup error, not a test
    # failure — say which type is missing before anything touches the cloud.
    if t4o_scope_includes s3  && [[ -z "${BT_S3_PRESENT:-}"  ]]; then
        t4o_die "Scope '$T4O_BT_SCOPE' includes S3, but $f defines no s3 backup target."
    fi
    if t4o_scope_includes nfs && [[ -z "${BT_NFS_PRESENT:-}" ]]; then
        t4o_die "Scope '$T4O_BT_SCOPE' includes NFS, but $f defines no nfs backup target."
    fi
}

# Host part of a target's endpoint, for the reachability probes.
#   S3  — hostname from the endpoint URL
#   NFS — server part of <server>:/<export>
t4o_target_host() {
    case "$1" in
      s3)  echo "${BT_S3_ENDPOINT}" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##' ;;
      nfs) echo "${BT_NFS_EXPORT%%:*}" ;;
    esac
}

t4o_is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# ---------------------------------------------------------------------------
# Test resource naming
#
# Role-suffixed even in single-target mode, so a later run against the other
# target cannot collide with leftovers from this one.
# ---------------------------------------------------------------------------
export TEST_IMAGE_NAME="${TEST_IMAGE_NAME:-ubuntu}"
export TEST_FLAVOR="${TEST_FLAVOR:-m1.tiny}"
export TEST_NETWORK="${TEST_NETWORK:-demo-network}"
export TEST_VOLUME_SIZE="${TEST_VOLUME_SIZE:-1}"

t4o_vm_name()       { echo "trilio-test-vm-$1"; }
t4o_workload_name() { echo "trilio-test-workload-$1"; }
t4o_snapshot_name() { echo "trilio-test-snapshot-$1"; }
t4o_volume_name()   { echo "trilio-test-vol-$1-$2"; }   # <role> <volume-type>

# ---------------------------------------------------------------------------
# Entry point — call this once from each numbered script
# ---------------------------------------------------------------------------
t4o_init() {
    detect_distro
    _t4o_set_distro_constants
    if [[ -z "${OS_PASSWORD:-}" ]]; then
        discover_cloud_admin
    fi
}
