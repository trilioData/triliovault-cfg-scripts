#!/usr/bin/env bash
# Installs prometheus/node_exporter on every unit that runs a Trilio T4O
# service, scoped (via --collector.systemd.unit-include) to just those
# service names so Prometheus gets per-unit systemd health without noise
# from every other service on the box.
#
# Run from the Juju client/bastion host, with a working `juju status`
# against the model that has the trilio-* applications deployed.

set -euo pipefail
cd "$(dirname "$0")"
source ../common.sh

NODE_EXPORTER_VERSION="1.8.2"
UNITS=(
  "trilio-wlm/0"
  "trilio-dm-api/0"
  "trilio-data-mover/0"
  "trilio-data-mover/1"
  "trilio-data-mover/2"
  "trilio-horizon-plugin/0"
)

TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading node_exporter ${NODE_EXPORTER_VERSION}..."
  curl -sSLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"
fi
tar xzf "${TARBALL}"
BINARY="node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter"

echo "=================================================="
echo "Deploying node_exporter to ${#UNITS[@]} Trilio units"
echo "=================================================="

TARGETS_FILE="../prometheus/node_exporter_targets.json"
echo "[" > "${TARGETS_FILE}"
first=true

for unit in "${UNITS[@]}"; do
  ip=$(require_unit "${unit}")
  echo "--- ${unit} (${ip}) ---"

  juju scp "${BINARY}" "${unit}:/tmp/node_exporter"
  juju scp "node_exporter.service" "${unit}:/tmp/node_exporter.service"
  juju ssh "${unit}" "
    sudo mv /tmp/node_exporter /usr/local/bin/node_exporter &&
    sudo chmod +x /usr/local/bin/node_exporter &&
    sudo mv /tmp/node_exporter.service /etc/systemd/system/node_exporter.service &&
    sudo systemctl daemon-reload &&
    sudo systemctl enable node_exporter &&
    sudo systemctl restart node_exporter &&
    sudo systemctl is-active node_exporter
  "

  [[ "${first}" == true ]] && first=false || echo "," >> "${TARGETS_FILE}"
  printf '  {"targets": ["%s:9100"], "labels": {"trilio_unit": "%s"}}' "${ip}" "${unit}" >> "${TARGETS_FILE}"
done
echo "]" >> "${TARGETS_FILE}"

echo ""
echo "=================================================="
echo "node_exporter deployed on all units."
echo "Target list written to ${TARGETS_FILE} for Prometheus file_sd_config."
echo "=================================================="
