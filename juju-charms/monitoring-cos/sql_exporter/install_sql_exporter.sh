#!/bin/bash
# Runs ON the trilio-wlm unit (copied there by deploy.sh).
# Installs sql_exporter as a systemd service that reads the workloadmgr DB
# through the unit's local mysql-router, reusing the DB credentials of the
# trilio-wlm charm (/etc/triliovault-wlm/triliovault-wlm.conf, or the older
# /etc/workloadmgr/workloadmgr.conf). Credentials are never printed.
#
# Usage: sudo ./install_sql_exporter.sh <sql_exporter_version> <work_dir>
set -euo pipefail

VERSION=${1:?sql_exporter version required}
WORK_DIR=${2:?directory containing sql_exporter.yml and trilio-sql-exporter.service required}
CONF_DIR=/etc/sql_exporter

if ! id sql_exporter >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin sql_exporter
fi

if ! /usr/local/bin/sql_exporter -version 2>&1 | grep -q "${VERSION}"; then
    TARBALL="sql_exporter-${VERSION}.linux-amd64.tar.gz"
    TMP=$(mktemp -d)
    curl -fsSL -o "${TMP}/${TARBALL}" \
        "https://github.com/burningalchemist/sql_exporter/releases/download/${VERSION}/${TARBALL}"
    tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
    install -m 0755 "${TMP}/sql_exporter-${VERSION}.linux-amd64/sql_exporter" /usr/local/bin/sql_exporter
    rm -rf "${TMP}"
fi

mkdir -p "${CONF_DIR}"
# Build the DSN from the oslo.db connection string and render the config.
python3 - "${WORK_DIR}/sql_exporter.yml" "${CONF_DIR}/sql_exporter.yml" <<'EOF'
import configparser, json, sys
from urllib.parse import urlsplit

template, target = sys.argv[1:3]
connection = None
for conf in ("/etc/triliovault-wlm/triliovault-wlm.conf", "/etc/workloadmgr/workloadmgr.conf"):
    cp = configparser.RawConfigParser(strict=False)
    if not cp.read(conf):
        continue
    for section, key in (("database", "connection"), ("DEFAULT", "sql_connection")):
        if cp.has_option(section, key):
            connection = cp.get(section, key)
            break
    if connection:
        break
if not connection:
    sys.exit("workloadmgr DB connection not found in the trilio-wlm config")
url = urlsplit(connection)
if not url.scheme.startswith("mysql"):
    sys.exit("unsupported database connection scheme: %s" % url.scheme)
# netloc keeps the user:password URL-encoded exactly as oslo.db uses it
creds, _, host = url.netloc.rpartition("@")
if ":" not in host:
    host += ":3306"
dsn = "mysql://%s@%s/workloadmgr" % (creds, host)
with open(template) as f:
    rendered = f.read().replace('"__TRILIO_DSN__"', json.dumps(dsn))
with open(target, "w") as f:
    f.write(rendered)
EOF
chown root:sql_exporter "${CONF_DIR}/sql_exporter.yml"
chmod 0640 "${CONF_DIR}/sql_exporter.yml"

install -m 0644 "${WORK_DIR}/trilio-sql-exporter.service" /etc/systemd/system/trilio-sql-exporter.service
systemctl daemon-reload
systemctl enable trilio-sql-exporter
systemctl restart trilio-sql-exporter

METRICS=""
for _ in $(seq 1 15); do
    if METRICS=$(curl -fs http://127.0.0.1:9399/metrics); then
        break
    fi
    sleep 2
done
if [ -z "${METRICS}" ]; then
    echo "ERROR: sql_exporter is not answering on :9399, check: journalctl -u trilio-sql-exporter" >&2
    exit 1
fi
COUNT=$(grep -cE '^(mysql_trilio_|trilio_|openstack_protected_vm)' <<<"${METRICS}" || true)
if [ "${COUNT}" -eq 0 ]; then
    echo "WARNING: sql_exporter is up but returned no Trilio series (empty workloadmgr DB or query errors)," \
         "check: journalctl -u trilio-sql-exporter" >&2
fi
echo "trilio-sql-exporter is up on :9399 (${COUNT} Trilio series)"
