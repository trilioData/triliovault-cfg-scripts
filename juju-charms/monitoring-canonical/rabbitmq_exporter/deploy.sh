#!/usr/bin/env bash
# Installs rabbitmq_exporter on the bastion host (this machine), polling the
# RabbitMQ management API on rabbitmq-server/0, filtered to the "triliowlm"
# vhost that backs wlm/dm-api/data-mover/dms on this deployment.
#
# Creates a dedicated RabbitMQ user tagged "monitoring" (read-only access to
# the management API) rather than reusing a service account. Set
# RABBITMQ_MONITORING_PASSWORD yourself to pin the password, otherwise one
# is generated.

set -euo pipefail
cd "$(dirname "$0")"
source ../common.sh

RABBITMQ_EXPORTER_VERSION="1.0.0"
RABBITMQ_UNIT="rabbitmq-server/0"
RABBITMQ_MONITORING_USER="${RABBITMQ_MONITORING_USER:-prometheus_monitor}"
RABBITMQ_MONITORING_PASSWORD="${RABBITMQ_MONITORING_PASSWORD:-$(openssl rand -hex 16)}"

rabbit_ip=$(require_unit "${RABBITMQ_UNIT}")

echo "=================================================="
echo "Creating RabbitMQ monitoring user on ${RABBITMQ_UNIT}"
echo "=================================================="
juju ssh "${RABBITMQ_UNIT}" "
  sudo rabbitmqctl add_user '${RABBITMQ_MONITORING_USER}' '${RABBITMQ_MONITORING_PASSWORD}' 2>/dev/null ||
    sudo rabbitmqctl change_password '${RABBITMQ_MONITORING_USER}' '${RABBITMQ_MONITORING_PASSWORD}'
  sudo rabbitmqctl set_user_tags '${RABBITMQ_MONITORING_USER}' monitoring
  sudo rabbitmqctl set_permissions -p triliowlm '${RABBITMQ_MONITORING_USER}' '.*' '.*' '.*'
"

echo "=================================================="
echo "Deploying rabbitmq_exporter on $(hostname) (bastion)"
echo "=================================================="

sudo mkdir -p /etc/rabbitmq_exporter
RABBITMQ_HOST="${rabbit_ip}" \
  RABBITMQ_MONITORING_USER="${RABBITMQ_MONITORING_USER}" \
  RABBITMQ_MONITORING_PASSWORD="${RABBITMQ_MONITORING_PASSWORD}" \
  envsubst < rabbitmq-exporter.env.template | sudo tee /etc/rabbitmq_exporter/rabbitmq-exporter.env > /dev/null
sudo chmod 600 /etc/rabbitmq_exporter/rabbitmq-exporter.env

TARBALL="rabbitmq_exporter_${RABBITMQ_EXPORTER_VERSION}_linux_amd64.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading rabbitmq_exporter ${RABBITMQ_EXPORTER_VERSION}..."
  curl -sSLO "https://github.com/kbudde/rabbitmq_exporter/releases/download/v${RABBITMQ_EXPORTER_VERSION}/${TARBALL}"
fi
tar xzf "${TARBALL}"
sudo mv rabbitmq_exporter /usr/local/bin/rabbitmq_exporter
sudo chmod +x /usr/local/bin/rabbitmq_exporter

sudo cp rabbitmq-exporter.service /etc/systemd/system/rabbitmq-exporter.service
sudo systemctl daemon-reload
sudo systemctl enable rabbitmq-exporter
sudo systemctl restart rabbitmq-exporter
sleep 2
sudo systemctl is-active rabbitmq-exporter
curl -sf localhost:9419/metrics | head -5 || true

echo ""
echo "=================================================="
echo "rabbitmq_exporter deployed, listening on :9419"
echo "Monitoring user: ${RABBITMQ_MONITORING_USER} (password not echoed — see /etc/rabbitmq_exporter/rabbitmq-exporter.env on this host)"
echo "=================================================="
