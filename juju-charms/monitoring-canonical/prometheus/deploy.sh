#!/usr/bin/env bash
# Installs Prometheus (Canonical snap) on the bastion host and configures it
# to scrape the four exporters deployed by the sibling deploy.sh scripts.
#
# Run node_exporter/deploy.sh and sql_exporter/deploy.sh first — this script
# reads trilio-wlm/0's address from `juju status` and the node_exporter
# targets file they produce.

set -euo pipefail
cd "$(dirname "$0")"
source ../common.sh

echo "=================================================="
echo "Installing Prometheus (snap) on $(hostname) (bastion)"
echo "=================================================="

if ! snap list prometheus >/dev/null 2>&1; then
  sudo snap install prometheus
fi

WLM_IP=$(require_unit "trilio-wlm/0")

sudo mkdir -p /var/snap/prometheus/current/file_sd
if [[ -f node_exporter_targets.json ]]; then
  sudo cp node_exporter_targets.json /var/snap/prometheus/current/file_sd/node_exporter_targets.json
else
  echo "WARNING: node_exporter_targets.json not found — run node_exporter/deploy.sh first." >&2
  echo "[]" | sudo tee /var/snap/prometheus/current/file_sd/node_exporter_targets.json > /dev/null
fi

SQL_EXPORTER_TARGET="${WLM_IP}:9399" envsubst '${SQL_EXPORTER_TARGET}' < prometheus.yml | \
  sudo tee /var/snap/prometheus/current/prometheus.yml > /dev/null

sudo snap restart prometheus
sleep 3
curl -sf localhost:9090/-/healthy

echo ""
echo "=================================================="
echo "Prometheus running on :9090. Check http://localhost:9090/targets"
echo "=================================================="
