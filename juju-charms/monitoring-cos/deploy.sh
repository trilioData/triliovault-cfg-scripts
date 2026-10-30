#!/bin/bash
# Trilio (T4O) backup monitoring on Canonical Observability Stack (COS).
#
# COS equivalent of redhat-director-scripts/monitoring-openshift:
#   sql-exporter Deployment       -> sql_exporter systemd service on the trilio-wlm leader unit
#   sql-exporter ServiceMonitor   -> prometheus-scrape-target-k8s app in the COS model
#   openstack-exporter Deployment -> openstack-exporter charm + grafana-agent (cos-agent)
#   GrafanaDashboard              -> dashboard imported through the COS Grafana API
#
# Run from a host that can talk to both controllers: the OpenStack one (Juju 2.9,
# "juju") and the COS one (Juju 3.x, "juju_juju3" by default).
#
# Usage: ./deploy.sh [all|sql-exporter|openstack-exporter|scrape-target|dashboard|verify]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# OpenStack side (Juju 2.9)
JUJU=${JUJU:-juju}
OS_MODEL=${OS_MODEL:-}                       # empty = current model
WLM_APP=${WLM_APP:-trilio-wlm}
KEYSTONE_APP=${KEYSTONE_APP:-keystone}
VAULT_APP=${VAULT_APP:-vault}
GRAFANA_AGENT_APP=${GRAFANA_AGENT_APP:-grafana-agent}
OSE_APP=${OSE_APP:-openstack-exporter}
OSE_CHANNEL=${OSE_CHANNEL:-latest/stable}
OSE_SERIES=${OSE_SERIES:-jammy}
OSE_TO=${OSE_TO:-}                           # empty = LXD container on the trilio-wlm leader's host machine
SQL_EXPORTER_VERSION=${SQL_EXPORTER_VERSION:-0.24.10}
SQL_EXPORTER_PORT=9399

# COS side (Juju 3.x)
JUJU3=${JUJU3:-juju_juju3}
COS_MODEL=${COS_MODEL:-cos-controller:admin/cos}
COS_PROMETHEUS_APP=${COS_PROMETHEUS_APP:-prometheus}
COS_GRAFANA_APP=${COS_GRAFANA_APP:-grafana}
SCRAPE_APP=${SCRAPE_APP:-trilio-sql-exporter}
SCRAPE_CHANNEL=${SCRAPE_CHANNEL:-1/stable}
GRAFANA_URL=${GRAFANA_URL:-}                 # e.g. http://172.20.1.100/cos-grafana; empty = ask the grafana charm
GRAFANA_USER=${GRAFANA_USER:-admin}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD:-}       # empty = get-admin-password action
PROMETHEUS_URL=${PROMETHEUS_URL:-}           # e.g. http://172.20.1.100/cos-prometheus-0; used by verify

os_juju() {
    if [ -n "${OS_MODEL}" ]; then
        "${JUJU}" "$1" -m "${OS_MODEL}" "${@:2}"
    else
        "${JUJU}" "$@"
    fi
}

cos_juju() {
    "${JUJU3}" "$1" -m "${COS_MODEL}" "${@:2}"
}

log() {
    echo "==> $*"
}

# Prints "<unit> <machine> <ip>" for the leader unit of an OpenStack-side app
leader_of() {
    os_juju status "$1" --format=json | python3 -c '
import json, sys
app = json.load(sys.stdin)["applications"][sys.argv[1]]
for name, unit in app.get("units", {}).items():
    if unit.get("leader"):
        print(name, unit["machine"], unit["public-address"])
        break
else:
    sys.exit("no leader unit found for " + sys.argv[1])
' "$1"
}

os_app_exists() {
    os_juju status "$1" --format=json | python3 -c '
import json, sys
sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["applications"] else 1)' "$1"
}

cos_app_exists() {
    cos_juju status "$1" --format=json | python3 -c '
import json, sys
sys.exit(0 if sys.argv[1] in json.load(sys.stdin)["applications"] else 1)' "$1"
}

# "relation already exists" is fine when re-running
os_relate() {
    local out
    if ! out=$(os_juju relate "$1" "$2" 2>&1); then
        grep -qi "already exists" <<<"${out}" || { echo "${out}" >&2; return 1; }
    fi
}

cos_integrate() {
    local out
    if ! out=$(cos_juju integrate "$1" "$2" 2>&1); then
        grep -qi "already exists" <<<"${out}" || { echo "${out}" >&2; return 1; }
    fi
}

deploy_sql_exporter() {
    local unit machine ip
    read -r unit machine ip < <(leader_of "${WLM_APP}")
    log "Installing sql_exporter ${SQL_EXPORTER_VERSION} on ${unit} (${ip})"
    os_juju ssh "${unit}" "mkdir -p /tmp/trilio-sql-exporter"
    os_juju scp "${SCRIPT_DIR}/sql_exporter/sql_exporter.yml" \
                "${SCRIPT_DIR}/sql_exporter/trilio-sql-exporter.service" \
                "${SCRIPT_DIR}/sql_exporter/install_sql_exporter.sh" \
                "${unit}:/tmp/trilio-sql-exporter/"
    os_juju ssh "${unit}" "sudo bash /tmp/trilio-sql-exporter/install_sql_exporter.sh ${SQL_EXPORTER_VERSION} /tmp/trilio-sql-exporter; rc=\$?; rm -rf /tmp/trilio-sql-exporter; exit \$rc"
}

deploy_openstack_exporter() {
    if ! os_app_exists "${OSE_APP}"; then
        local to=${OSE_TO}
        if [ -z "${to}" ]; then
            local unit machine ip
            read -r unit machine ip < <(leader_of "${WLM_APP}")
            to="lxd:${machine%%/*}"
        fi
        log "Deploying ${OSE_APP} (${OSE_CHANNEL}, ${OSE_SERIES}) to ${to}"
        os_juju deploy openstack-exporter "${OSE_APP}" --channel "${OSE_CHANNEL}" --series "${OSE_SERIES}" --to "${to}"
    else
        log "${OSE_APP} already deployed"
    fi

    # Keystone endpoints are TLS-terminated with the Vault CA
    if os_app_exists "${VAULT_APP}"; then
        log "Setting ${OSE_APP} ssl_ca from ${VAULT_APP} root CA"
        local ca
        ca=$(os_juju run-action "${VAULT_APP}/leader" get-root-ca --wait --format=json | python3 -c '
import json, sys
for task in json.load(sys.stdin).values():
    print(task["results"]["output"])')
        os_juju config "${OSE_APP}" ssl_ca="${ca}"
    fi

    log "Relating ${OSE_APP} to ${KEYSTONE_APP} and ${GRAFANA_AGENT_APP}"
    os_relate "${OSE_APP}:credentials" "${KEYSTONE_APP}:identity-admin"
    os_relate "${OSE_APP}:cos-agent" "${GRAFANA_AGENT_APP}:cos-agent"
}

deploy_scrape_target() {
    local unit machine ip
    read -r unit machine ip < <(leader_of "${WLM_APP}")
    if ! cos_app_exists "${SCRAPE_APP}"; then
        log "Deploying ${SCRAPE_APP} (prometheus-scrape-target-k8s ${SCRAPE_CHANNEL}) in ${COS_MODEL}"
        cos_juju deploy prometheus-scrape-target-k8s "${SCRAPE_APP}" --channel "${SCRAPE_CHANNEL}"
    fi
    log "Pointing ${SCRAPE_APP} at ${ip}:${SQL_EXPORTER_PORT}"
    cos_juju config "${SCRAPE_APP}" targets="${ip}:${SQL_EXPORTER_PORT}" job_name=trilio-sql-exporter
    cos_integrate "${SCRAPE_APP}:metrics-endpoint" "${COS_PROMETHEUS_APP}:metrics-endpoint"
}

grafana_password() {
    if [ -n "${GRAFANA_PASSWORD}" ]; then
        echo "${GRAFANA_PASSWORD}"
        return
    fi
    cos_juju run "${COS_GRAFANA_APP}/leader" get-admin-password --format=json | python3 -c '
import json, sys
for task in json.load(sys.stdin).values():
    print(task["results"]["admin-password"])'
}

grafana_url() {
    if [ -n "${GRAFANA_URL}" ]; then
        echo "${GRAFANA_URL%/}"
        return
    fi
    cos_juju run "${COS_GRAFANA_APP}/leader" get-admin-password --format=json | python3 -c '
import json, sys
for task in json.load(sys.stdin).values():
    print(task["results"]["url"].rstrip("/"))'
}

import_dashboard() {
    local url password
    url=$(grafana_url)
    password=$(grafana_password)
    log "Importing Trilio dashboard into ${url}"
    python3 -c '
import json, sys
print(json.dumps({"dashboard": json.load(open(sys.argv[1])), "overwrite": True,
                  "message": "Trilio T4O dashboard (monitoring-cos/deploy.sh)"}))
' "${SCRIPT_DIR}/grafana/TrilioGrafanaDashboard.json" |
        curl -fsS -u "${GRAFANA_USER}:${password}" -H "Content-Type: application/json" \
             -X POST "${url}/api/dashboards/db" --data-binary @-
    echo
}

verify() {
    local unit machine ip
    read -r unit machine ip < <(leader_of "${WLM_APP}")
    log "sql_exporter on ${unit}"
    os_juju ssh "${unit}" "systemctl is-active trilio-sql-exporter; curl -fs http://127.0.0.1:${SQL_EXPORTER_PORT}/metrics | grep -cE '^(mysql_trilio_|trilio_|openstack_protected_vm)'" || true
    log "${OSE_APP} status"
    os_juju status "${OSE_APP}" || true
    log "${SCRAPE_APP} status"
    cos_juju status "${SCRAPE_APP}" || true
    if [ -n "${PROMETHEUS_URL}" ]; then
        local q
        for q in 'count(trilio_workload_info)' 'count(mysql_trilio_snapshots_info)' \
                 'count(openstack_identity_project_info)' 'count(openstack_nova_server_status)'; do
            printf '%-45s ' "${q}"
            curl -fsS -G "${PROMETHEUS_URL%/}/api/v1/query" --data-urlencode "query=${q}" |
                python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "NO DATA")'
        done
    fi
}

case "${1:-all}" in
    sql-exporter)       deploy_sql_exporter ;;
    openstack-exporter) deploy_openstack_exporter ;;
    scrape-target)      deploy_scrape_target ;;
    dashboard)          import_dashboard ;;
    verify)             verify ;;
    all)
        deploy_sql_exporter
        deploy_openstack_exporter
        deploy_scrape_target
        import_dashboard
        log "Done. Metrics take a few minutes to show up; run '$0 verify' to check."
        ;;
    *)
        echo "Usage: $0 [all|sql-exporter|openstack-exporter|scrape-target|dashboard|verify]" >&2
        exit 1
        ;;
esac
