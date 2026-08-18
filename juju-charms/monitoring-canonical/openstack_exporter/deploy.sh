#!/usr/bin/env bash
# Installs openstack-exporter on the bastion host (this machine), feeding
# the "Trilio Openstack Backup Monitor" dashboard's openstack_* metrics
# (openstack_nova_server_status, openstack_identity_project_info, ...).
#
# Credentials: by default this sources the admin openrc already present on
# this host (OPENRC_FILE, default /root/openrc) and maps its OS_* vars onto
# the OPENSTACK_* placeholders in clouds.yaml.template. To supply credentials
# explicitly instead, export the six OPENSTACK_* vars yourself and run with
# OPENRC_FILE=/dev/null.

set -euo pipefail
cd "$(dirname "$0")"

OPENSTACK_EXPORTER_VERSION="1.7.0"
OPENRC_FILE="${OPENRC_FILE:-/root/openrc}"

if [[ -f "${OPENRC_FILE}" && "${OPENRC_FILE}" != "/dev/null" ]]; then
  echo "Sourcing ${OPENRC_FILE} for admin credentials..."
  # This openrc re-derives creds live via `juju run ... leader-get admin_passwd`
  # and echoes them as a side effect — references an unset _juju_model_arg
  # (fine under plain bash, fatal under our `set -u`) and prints the password
  # to stdout. Relax -u for the source and discard its stdout so neither
  # bites us; the resulting exports still land in this shell either way.
  set +u
  # shellcheck disable=SC1090
  source "${OPENRC_FILE}" > /dev/null
  set -u
  export OPENSTACK_KEYSTONE_AUTH_URL="${OS_AUTH_URL}"
  export OPENSTACK_ADMIN_USER_NAME="${OS_USERNAME}"
  export OPENSTACK_ADMIN_USER_PASSWORD="${OS_PASSWORD}"
  export OPENSTACK_PROJECT_NAME="${OS_PROJECT_NAME}"
  export OPENSTACK_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME}"
  export OPENSTACK_PROJECT_DOMAIN_NAME="${OS_PROJECT_DOMAIN_NAME}"
  export OPENSTACK_REGION_NAME="${OS_REGION_NAME:-RegionOne}"
  CACERT_SRC="${OS_CACERT:-}"
else
  for v in OPENSTACK_KEYSTONE_AUTH_URL OPENSTACK_ADMIN_USER_NAME OPENSTACK_ADMIN_USER_PASSWORD \
           OPENSTACK_PROJECT_NAME OPENSTACK_USER_DOMAIN_NAME OPENSTACK_PROJECT_DOMAIN_NAME; do
    if [[ -z "${!v:-}" ]]; then
      echo "ERROR: ${v} is not set and ${OPENRC_FILE} was not used. Export it or point OPENRC_FILE at a valid openrc." >&2
      exit 1
    fi
  done
  export OPENSTACK_REGION_NAME="${OPENSTACK_REGION_NAME:-RegionOne}"
  CACERT_SRC="${OS_CACERT:-}"
fi

echo "=================================================="
echo "Deploying openstack-exporter on $(hostname) (bastion)"
echo "Auth URL: ${OPENSTACK_KEYSTONE_AUTH_URL}"
echo "=================================================="

sudo mkdir -p /etc/openstack-exporter

if [[ -n "${CACERT_SRC}" && -f "${CACERT_SRC}" ]]; then
  echo "Using CA bundle from ${CACERT_SRC}"
  sudo cp "${CACERT_SRC}" /etc/openstack-exporter/ca.crt
  export CACERT_LINE="cacert: /etc/openstack-exporter/ca.crt"
else
  echo "No CA bundle configured (plain HTTP or system-trusted endpoint) — omitting cacert."
  export CACERT_LINE=""
fi

envsubst < clouds.yaml.template | sudo tee /etc/openstack-exporter/clouds.yaml > /dev/null
sudo chmod 600 /etc/openstack-exporter/clouds.yaml

TARBALL="openstack-exporter_${OPENSTACK_EXPORTER_VERSION}_linux_amd64.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading openstack-exporter ${OPENSTACK_EXPORTER_VERSION}..."
  curl -sSLO "https://github.com/openstack-exporter/openstack-exporter/releases/download/v${OPENSTACK_EXPORTER_VERSION}/${TARBALL}"
fi
tar xzf "${TARBALL}"
sudo mv openstack-exporter /usr/local/bin/openstack-exporter
sudo chmod +x /usr/local/bin/openstack-exporter

sudo cp openstack-exporter.service /etc/systemd/system/openstack-exporter.service
sudo systemctl daemon-reload
sudo systemctl enable openstack-exporter
sudo systemctl restart openstack-exporter
sleep 2
sudo systemctl is-active openstack-exporter
curl -sf localhost:9180/metrics | head -5 || true

echo ""
echo "=================================================="
echo "openstack-exporter deployed, listening on :9180"
echo "=================================================="
