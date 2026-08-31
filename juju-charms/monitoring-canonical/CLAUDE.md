# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
directory.

## Purpose

This directory contains a Grafana + Prometheus monitoring stack for TrilioVault (T4O) on
**Canonical (Juju charms) OpenStack**. It is the machine-based equivalent of
`redhat-director-scripts/monitoring-openshift/`, reusing the same dashboards and exporter/query
logic wherever the underlying metrics are identical. It is **not a Juju charm** — unlike its
sibling directories in `juju-charms/`, this is a set of plain install/config scripts, because
there is no Kubernetes substrate on this class of deployment (COS Lite / Grafana Operator /
ServiceMonitors don't apply) and no packaged charm exists for any of these exporters.

## Architecture

```
Bastion host (Juju client)
  Prometheus (snap)  ──scrapes──> openstack-exporter   (local, :9180)
                      ──scrapes──> rabbitmq-exporter    (local, :9419)
                      ──scrapes──> sql-exporter          (trilio-wlm/0:9399)
                      ──scrapes──> node-exporter x6      (:9100 on each Trilio unit)
  Grafana (apt, official repo) ──queries──> Prometheus (local, :9090)

openstack-exporter  ──calls──> Keystone/Nova/Cinder public API (admin clouds.yaml)
rabbitmq-exporter   ──polls──> RabbitMQ management API on rabbitmq-server/0:15672
sql-exporter        ──queries──> mysql-router 127.0.0.1:3306 (workloadmgr DB)
node-exporter       ──runs on──> trilio-wlm, trilio-dm-api, trilio-data-mover x3,
                                  trilio-horizon-plugin
```

### Why sql_exporter is co-located, not on the bastion

`mysql-router` (the subordinate charm relating `trilio-wlm` to `mysql-innodb-cluster`) only listens
on `127.0.0.1:3306` on the `trilio-wlm` unit's own machine, for security. `sql_exporter` must
therefore run on that same machine — it cannot reach the DB from the bastion.

### Components

| Directory | Binary | Runs on | Metrics |
|-----------|--------|---------|---------|
| `node_exporter/` | `prometheus/node_exporter` | 6 Trilio units | systemd unit state + host CPU/mem/disk (feeds Trilio Service Health) |
| `sql_exporter/` | `burningalchemist/sql_exporter` | `trilio-wlm/0` | `workloadmgr` MySQL DB (feeds Backup Monitor) |
| `openstack_exporter/` | `openstack-exporter/openstack-exporter` | bastion | OpenStack infrastructure (feeds Backup Monitor) |
| `rabbitmq_exporter/` | `kbudde/rabbitmq_exporter` | bastion | RabbitMQ queue/exchange metrics (feeds RabbitMQ Queue Monitoring) |
| `prometheus/` | Canonical `prometheus` snap | bastion | scrapes all of the above |
| `grafana/` | Grafana OSS (apt.grafana.com) | bastion | dashboards + datasource |

### Dashboards

- **Trilio Openstack Backup Monitor** (`TrilioGrafanaDashboard.json`) — ported byte-identical from
  PR #1560 (`sql_exporter` + `openstack_exporter` metrics: snapshot/restore counts, backup size,
  quota usage, protected-VM counts).
- **Trilio RabbitMQ Queue Monitoring** (`TrilioRabbitMQDashboard.json`) — ported byte-identical
  from PR #1560 (`rabbitmq_exporter` metrics, split into Controller/Compute node sections).
- **Trilio Service Health** (`TrilioServiceHealthDashboard.json`) — **new**, not a port. Machine
  equivalent of the RHOSO "Pod Health Overview" dashboard (which depends on kube-state-metrics —
  no Kubernetes here). Uses `node_exporter`'s systemd collector, scoped to Trilio's actual unit
  files, plus host CPU/mem/disk.

Both ported dashboards keep their original datasource UID placeholders unmodified in the checked-in
JSON (`87baa079-f0c8-4e76-93be-133b7a1cf956` in the Backup Monitor file, `${DS_PROMETHEUS}` in the
RabbitMQ and new Service Health files) — `grafana/deploy.sh` resolves `${DS_PROMETHEUS}` to that
same fixed UID at deploy time (the UID is also the one `grafana-datasource.yaml` provisions), so
diffing these files against upstream PRs stays meaningful.

## Deployment order & prerequisites

Run every `deploy.sh` from the Juju client/bastion host, with a working `juju status` against the
model containing the `trilio-*` applications. Requires: `juju`, `jq`, `curl`, `envsubst`, `openssl`.

### 1. node_exporter (all 6 Trilio units)
```bash
cd node_exporter/
bash deploy.sh
```
Installs on `trilio-wlm/0`, `trilio-dm-api/0`, `trilio-data-mover/{0,1,2}`,
`trilio-horizon-plugin/0` via `juju scp`/`juju ssh`. Writes
`../prometheus/node_exporter_targets.json` (Prometheus `file_sd_config` target list) — run this
step before `prometheus/deploy.sh`.

### 2. sql_exporter (trilio-wlm/0)
```bash
cd sql_exporter/
bash deploy.sh
```
Derives the DSN from `/etc/triliovault-wlm/triliovault-wlm.conf` (`sql_connection` under
`[DEFAULT]`) on `trilio-wlm/0` itself — the credential never leaves that unit. Override with `DSN_OVERRIDE='mysql://USER:PASS@tcp(HOST:3306)/workloadmgr' bash deploy.sh`.

### 3. openstack_exporter (bastion)
```bash
cd openstack_exporter/
bash deploy.sh
```
Defaults to sourcing `/root/openrc` for admin credentials. Point elsewhere with
`OPENRC_FILE=/path/to/openrc bash deploy.sh`, or export the six `OPENSTACK_*` vars yourself and run
with `OPENRC_FILE=/dev/null bash deploy.sh`.

### 4. rabbitmq_exporter (bastion)
```bash
cd rabbitmq_exporter/
bash deploy.sh
```
Creates a dedicated `monitoring`-tagged RabbitMQ user (`prometheus_monitor` by default) on
`rabbitmq-server/0` via `rabbitmqctl` rather than reusing a service account. Set
`RABBITMQ_MONITORING_PASSWORD` to pin the password; otherwise one is generated and never echoed.

### 5. Prometheus (bastion)
```bash
cd prometheus/
bash deploy.sh
```
Run after steps 1 and 2 — it reads `trilio-wlm/0`'s address for the sql-exporter scrape target and
copies the node_exporter target file written in step 1.

### 6. Grafana (bastion)
```bash
cd grafana/
bash deploy.sh
```

## Key conventions

- **sql_exporter DSN**: `sql-exporter.yml`'s `data_source_name` is the literal string `"${DSN}"` —
  `sql_exporter` itself expands this against its process environment at load time (via
  `EnvironmentFile=/etc/sql_exporter/dsn.env` in the systemd unit), so the file never needs the
  real credential.
- **No credentials checked in**: `*.template` files use `${VAR}` shell-style placeholders,
  substituted by `deploy.sh` via `envsubst` at install time, mirroring the `${VAR}` convention in
  `redhat-director-scripts/monitoring-openshift/openstack_exporter/openstack-exporter-clouds-cm.yaml`.
- **rabbitmq_exporter vhost filter**: `INCLUDE_VHOST=^triliowlm$`. Unlike RHOSO (which splits
  `workloadmgr`/`dmapi` into separate vhosts under the Operator-managed RabbitMQ cluster), the
  Canonical charms share a single `triliowlm` vhost across wlm/dm-api/data-mover/dms — confirmed
  via `rabbitmqctl list_vhosts` on this deployment. The Grafana dashboard's `$vhost` variable
  discovers whatever vhost names Prometheus actually has data for
  (`label_values(rabbitmq_queue_messages_ready, vhost)`), so no dashboard edit was needed for this
  difference — it just shows `triliowlm` in the dropdown instead of `workloadmgr`/`dmapi`.
- **node_exporter systemd scope**: `--collector.systemd.unit-include` is restricted to
  `wlm-*`, `tvault-*`, `trilio-dms-server`, `apache2` — without this filter every systemd unit on
  the box gets a metric series, which is noisy and mostly irrelevant.
- **Flat network, no auth on exporter ports**: all exporters listen unauthenticated on their
  metrics ports across the lab's flat network. Fine for this environment; for production, firewall
  those ports to the Prometheus host only.
- **sql_exporter reuses the wlm service DB account** by default (read+write access it doesn't
  need). Recommended hardening: create a dedicated read-only MySQL user for it instead.
