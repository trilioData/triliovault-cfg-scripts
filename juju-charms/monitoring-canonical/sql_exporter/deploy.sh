#!/usr/bin/env bash
# Installs sql_exporter on trilio-wlm/0, co-located with mysql-router since
# mysql-router only listens on 127.0.0.1:3306 on that unit's own machine.
#
# The DSN is read out of /etc/triliovault-wlm/triliovault-wlm.conf ON the
# trilio-wlm unit itself and written straight to /etc/sql_exporter/dsn.env there — the
# credential is never printed to, or captured on, the bastion running this
# script. Set DSN_OVERRIDE below to skip auto-detection and supply your own
# DSN (format: mysql://USER:PASSWORD@tcp(HOST:3306)/workloadmgr).

set -euo pipefail
cd "$(dirname "$0")"
source ../common.sh

UNIT="trilio-wlm/0"
SQL_EXPORTER_VERSION="0.16.0"
DSN_OVERRIDE="${DSN_OVERRIDE:-}"

ip=$(require_unit "${UNIT}")
echo "=================================================="
echo "Deploying sql_exporter on ${UNIT} (${ip})"
echo "=================================================="

TARBALL="sql_exporter-${SQL_EXPORTER_VERSION}.linux-amd64.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  echo "Downloading sql_exporter ${SQL_EXPORTER_VERSION}..."
  curl -sSLO "https://github.com/burningalchemist/sql_exporter/releases/download/${SQL_EXPORTER_VERSION}/${TARBALL}"
fi
tar xzf "${TARBALL}"
BINARY="sql_exporter-${SQL_EXPORTER_VERSION}.linux-amd64/sql_exporter"

echo "Pushing binary + config + unit file to ${UNIT}..."
juju scp "${BINARY}" "${UNIT}:/tmp/sql_exporter"
juju scp "sql-exporter.yml" "${UNIT}:/tmp/sql-exporter.yml"
juju scp "sql-exporter.service" "${UNIT}:/tmp/sql-exporter.service"

echo "Installing on ${UNIT}..."
juju ssh "${UNIT}" "
  sudo mkdir -p /etc/sql_exporter &&
  sudo mv /tmp/sql_exporter /usr/local/bin/sql_exporter &&
  sudo chmod +x /usr/local/bin/sql_exporter &&
  sudo mv /tmp/sql-exporter.yml /etc/sql_exporter/sql-exporter.yml &&
  sudo mv /tmp/sql-exporter.service /etc/systemd/system/sql-exporter.service
"

if [[ -n "${DSN_OVERRIDE}" ]]; then
  echo "Writing operator-supplied DSN..."
  juju ssh "${UNIT}" "sudo bash -c 'echo DSN=\"${DSN_OVERRIDE}\" > /etc/sql_exporter/dsn.env && chmod 600 /etc/sql_exporter/dsn.env'"
else
  echo "Deriving DSN from /etc/workloadmgr/workloadmgr.conf on-unit (credential stays on ${UNIT})..."
  juju ssh "${UNIT}" "sudo python3 - <<'PY'
import configparser
from urllib.parse import urlparse

cfg = configparser.ConfigParser()
cfg.read('/etc/triliovault-wlm/triliovault-wlm.conf')
conn = None
for section in ('DEFAULT', 'database'):
    if cfg.has_option(section, 'sql_connection') or cfg.has_option(section, 'connection'):
        conn = cfg.get(section, 'sql_connection', fallback=None) or cfg.get(section, 'connection', fallback=None)
        break
if not conn:
    raise SystemExit('Could not find sql_connection/connection in workloadmgr.conf')

u = urlparse(conn)
# sql_exporter validates data_source_name with net/url and dials the plain
# host:port from it directly — it does NOT translate a go-sql-driver-style
# tcp(host:port) wrapper (that form either fails net/url's port validation
# or, without a port, gets dialed as a literal hostname). Standard
# 'mysql://user:pass@host:port/db' is what it actually expects.
dsn = 'mysql://{}:{}@{}:{}/{}'.format(
    u.username, u.password, u.hostname, u.port or 3306, u.path.lstrip('/')
)
with open('/etc/sql_exporter/dsn.env', 'w') as f:
    f.write('DSN={}\n'.format(dsn))
import os
os.chmod('/etc/sql_exporter/dsn.env', 0o600)
print('DSN written to /etc/sql_exporter/dsn.env (host: {})'.format(u.hostname))
PY
"
fi

juju ssh "${UNIT}" "
  sudo systemctl daemon-reload &&
  sudo systemctl enable sql-exporter &&
  sudo systemctl restart sql-exporter &&
  sleep 2 &&
  sudo systemctl is-active sql-exporter &&
  curl -sf localhost:9399/metrics | head -5 || true
"

echo ""
echo "=================================================="
echo "sql_exporter deployed on ${UNIT}, listening on :9399"
echo "Prometheus target: ${ip}:9399"
echo "=================================================="
