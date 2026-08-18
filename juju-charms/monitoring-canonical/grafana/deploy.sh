#!/usr/bin/env bash
# Installs Grafana OSS from the official Grafana Labs apt repo on the
# bastion host (the `grafana` snap is stuck at 6.7.4 from 2020 — too old
# for these dashboards' panel schema) and provisions the Prometheus
# datasource plus the three Trilio dashboards via file-based provisioning.

set -euo pipefail
cd "$(dirname "$0")"

DATASOURCE_UID="87baa079-f0c8-4e76-93be-133b7a1cf956"

echo "=================================================="
echo "Installing Grafana on $(hostname) (bastion)"
echo "=================================================="

if ! command -v grafana-server >/dev/null 2>&1; then
  sudo mkdir -p /etc/apt/keyrings/
  curl -fsSL https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
    sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y grafana
fi

sudo mkdir -p /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards/trilio

sudo cp grafana-datasource.yaml /etc/grafana/provisioning/datasources/grafana-datasource.yaml
sudo cp dashboards-provider.yaml /etc/grafana/provisioning/dashboards/dashboards-provider.yaml

# TrilioGrafanaDashboard.json already ships with this exact uid baked in — copy verbatim.
sudo cp TrilioGrafanaDashboard.json /etc/grafana/provisioning/dashboards/trilio/TrilioGrafanaDashboard.json

# TrilioRabbitMQDashboard.json and TrilioServiceHealthDashboard.json use the
# ${DS_PROMETHEUS} placeholder (Grafana Operator "input" convention, carried
# over unmodified from the RHOSO dashboards) — resolve it to the datasource
# uid configured above. The checked-in files are left untouched.
sed "s/\${DS_PROMETHEUS}/${DATASOURCE_UID}/g" TrilioRabbitMQDashboard.json | \
  sudo tee /etc/grafana/provisioning/dashboards/trilio/TrilioRabbitMQDashboard.json > /dev/null
sed "s/\${DS_PROMETHEUS}/${DATASOURCE_UID}/g" TrilioServiceHealthDashboard.json | \
  sudo tee /etc/grafana/provisioning/dashboards/trilio/TrilioServiceHealthDashboard.json > /dev/null

sudo systemctl enable --now grafana-server
sudo systemctl restart grafana-server
sleep 3
curl -sf localhost:3000/api/health

echo ""
echo "=================================================="
echo "Grafana running on :3000 (default login admin/admin, forced change on first login)"
echo "Dashboards provisioned: Trilio Openstack Backup Monitor, Trilio RabbitMQ Queue Monitoring, Trilio Service Health"
echo "=================================================="
