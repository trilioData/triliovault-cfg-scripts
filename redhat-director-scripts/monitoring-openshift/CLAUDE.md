# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This directory contains the OpenShift user workload monitoring stack for TrilioVault on RHOSO 18. It deploys four Prometheus exporters into the `trilio-monitoring` namespace and Grafana into `openshift-user-workload-monitoring` to expose TrilioVault backup/restore metrics.

## Namespace split (important)

**Exporters live in `trilio-monitoring`** — not `openshift-user-workload-monitoring`. OpenShift's user workload Prometheus uses a `serviceMonitorNamespaceSelector` that excludes namespaces with `openshift.io/cluster-monitoring: "true"`. Because `openshift-user-workload-monitoring` carries that label, any ServiceMonitor placed there is silently ignored. The `trilio-monitoring` namespace does not have that label and is correctly watched.

**Grafana stays in `openshift-user-workload-monitoring`** — it is monitoring infrastructure, not a user workload.

## Architecture

```
Prometheus (OpenShift UWM) ──scrapes──> kube-state-metrics   [trilio-monitoring:8080]
                           ──scrapes──> openstack-exporter    [trilio-monitoring:9180]
                           ──scrapes──> sql-exporter          [trilio-monitoring:9399]
                           ──scrapes──> rabbitmq-exporter     [trilio-monitoring:9419]
Grafana ──queries──> Thanos Querier ──reads──> Prometheus
rabbitmq-exporter ──polls──> RabbitMQ management API (port 15671 HTTPS) in trilio-openstack namespace
```

### Components

| Directory | Exporter | Metrics |
|-----------|----------|---------|
| `kube-state-metrics/` | `registry.k8s.io/kube-state-metrics:v2.18.0` | Kubernetes resource state |
| `openstack_exporter/` | `ghcr.io/openstack-exporter/openstack-exporter:latest` | OpenStack infrastructure |
| `sql_exporter/` | `docker.io/burningalchemist/sql_exporter:latest` | workloadmgr MySQL DB |
| `rabbitmq_exporter/` | `docker.io/kbudde/rabbitmq-exporter:latest` | RabbitMQ queue metrics (workloadmgr & dmapi vhosts) |
| `grafana/` | Integreatly Grafana Operator v12.1.0 | Dashboards + datasource |

### SQL Exporter Metrics

The `sql_exporter/sql-exporter-config.yaml` defines the `mysql_workloads` collector, querying the `workloadmgr` database for:
- `mysql_trilio_snapshots_info` — snapshot counts by project/status (successful, failed, running)
- `mysql_trilio_restore_info` — restore counts by project/status
- `mysql_trilio_backup_size_info` — backup size in GB by project
- `mysql_trilio_snapshots_status` — per-snapshot detail with workload/snapshot IDs
- `openstack_protected_vm` — count of unique VMs in active workloads per project
- `trilio_allowed_quota_value` / `trilio_quota_high_watermark` — quota tracking
- `trilio_workload_info` / `trilio_workload_vm_info` — full workload metadata

## Deployment Order & Prerequisites

### 1. Enable user workload monitoring (once per cluster)
```bash
oc apply -f cm-cluster-monitoring-config.yaml
```

### 2. kube-state-metrics
```bash
cd kube-state-metrics/
bash deploy.sh
```
The script validates the namespace and ServiceMonitor CRD before applying manifests and waits for rollout.

### 3. openstack-exporter

Create the Keystone CA secret first (reads from `combined-ca-bundle` secret in `openstack` namespace):
```bash
cd openstack_exporter/
bash create_keystone_cacert_secret.sh
```

Substitute environment variables in the clouds ConfigMap, then apply:
```bash
oc apply -f openstack-exporter-clouds-cm.yaml
oc apply -f openstack-exporter-deployment.yaml
oc apply -f openstack-exporter-service.yaml
oc apply -f openstack-exporter-servicemonitor.yaml
oc apply -f openstack-exporter-route.yaml
```

The `openstack-exporter-clouds-cm.yaml` uses `${VAR}` placeholders — substitute before applying:
`OPENSTACK_KEYSTONE_AUTH_URL`, `OPENSTACK_ADMIN_USER_NAME`, `OPENSTACK_ADMIN_USER_PASSWORD`, `OPENSTACK_PROJECT_NAME`, `OPENSTACK_USER_DOMAIN_NAME`, `OPENSTACK_PROJECT_DOMAIN_NAME`

### 4. sql-exporter

Create the DSN secret (must match format `mysql://USER:PASSWORD@HOST:3306/workloadmgr`):
```bash
oc create secret generic sql-exporter-secret \
  --from-literal=dsn='mysql://USER:PASSWORD@HOST:3306/workloadmgr' \
  -n openshift-user-workload-monitoring
```

Then apply:
```bash
cd sql_exporter/
oc apply -f sql-exporter-config.yaml
oc apply -f sql-exporter-deployment.yaml
oc apply -f sql-exporter-service.yaml
oc apply -f sql-exporter-servicemonitor.yaml
oc apply -f sql-exporter-route.yaml
```

### 5. rabbitmq-exporter

The exporter connects to the RabbitMQ management API (port 15671 HTTPS) and scrapes queue/exchange metrics filtered to the `workloadmgr` and `dmapi` vhosts.

#### Vhost → node-type mapping

| RabbitMQ vhost | Trilio components | Node type |
|----------------|-------------------|-----------|
| `workloadmgr`  | wlm-api, wlm-workloads, wlm-cron, wlm-scheduler | Controller |
| `dmapi`        | datamover, trilio-dms (per compute FQDN) | Compute |

Both vhosts live in the **same** central `trilio-rabbitmq-cluster`. A single exporter instance covers both, and the Grafana dashboard splits them into dedicated **Controller Node** and **Compute Node** sections automatically.

The management API user must have the `monitoring` or `administrator` tag. In RHOSO 18 retrieve the default admin credentials with:
```bash
oc get secret trilio-rabbitmq-cluster-default-user -n trilio-openstack -o yaml
```

**To freshly install:**
```bash
cd rabbitmq_exporter/
export RABBITMQ_HOST="trilio-rabbitmq-cluster.trilio-openstack.svc"
export RABBITMQ_MONITORING_USER="<management-user>"
export RABBITMQ_MONITORING_PASSWORD="<management-password>"
envsubst < rabbitmq-exporter-secret.yaml | oc apply -f -
bash deploy.sh
```

Apply the Grafana dashboard CR after the exporter is running:
```bash
oc apply -f grafana/grafana-trilio-rabbitmq-dashboard.yaml
```

#### Multi-instance deployment (optional — only needed for separate RabbitMQ clusters)

If a future deployment has a dedicated RabbitMQ cluster per compute node (rather than the shared central cluster), deploy one exporter per cluster. The single `ServiceMonitor` already selects all of them via `app: rabbitmq-exporter`. Each instance is distinguished in Prometheus by the `rabbitmq-exporter-instance` label set on the Service and Pod, which the `ServiceMonitor` relabels into the `instance` metric label. The dashboard **Exporter Instance** variable then lets you filter by instance.

Steps to add a second instance (e.g. for `compute-0`):
1. Copy `rabbitmq-exporter-secret.yaml` → `rabbitmq-exporter-secret-compute-0.yaml`; update `RABBIT_URL`.
2. Copy `rabbitmq-exporter-deployment.yaml` → `rabbitmq-exporter-deployment-compute-0.yaml`; set:
   - `metadata.name: rabbitmq-exporter-compute-0`
   - pod label `rabbitmq-exporter-instance: compute-0`
3. Copy `rabbitmq-exporter-service.yaml` → `rabbitmq-exporter-service-compute-0.yaml`; set:
   - `metadata.name: rabbitmq-exporter-compute-0`
   - `labels.rabbitmq-exporter-instance: compute-0`
4. Apply both new manifests — the existing `ServiceMonitor` picks them up automatically.

**Note**: If a NetworkPolicy in the `trilio-openstack` namespace blocks ingress, add an ingress rule allowing TCP 15671 before deploying.

### 6. Grafana

Create the credentials secret (base64-encode the values):
```bash
oc apply -f grafana/grafana-secret-creds_original.yaml  # after substituting base64 values
oc apply -f grafana/grafana-instance.yaml
oc apply -f grafana/grafana-datasource.yaml
# Import TrilioGrafanaDashboard.json via Grafana UI or as a GrafanaDashboard CR
```

#### Grafana Dashboards

Each dashboard is stored as a JSON file and loaded via a ConfigMap + GrafanaDashboard CR pair.

**Trilio Backup/Restore Dashboard** (SQL exporter metrics):
```bash
oc create configmap trilio-backup-dashboard \
  --from-file=dashboard.json=grafana/TrilioGrafanaDashboard.json \
  -n openshift-user-workload-monitoring
```

**Trilio Service Health Dashboard** (kube-state-metrics — deployment availability):
```bash
oc create configmap trilio-service-health-dashboard \
  --from-file=dashboard.json=grafana/TrilioServiceHealthDashboard.json \
  -n openshift-user-workload-monitoring
oc apply -f grafana/grafana-trilio-service-health-dashboard.yaml
```

**Trilio RabbitMQ Dashboard** (rabbitmq-exporter metrics):
```bash
oc create configmap trilio-rabbitmq-dashboard \
  --from-file=dashboard.json=grafana/TrilioRabbitMQDashboard.json \
  -n openshift-user-workload-monitoring
oc apply -f grafana/grafana-trilio-rabbitmq-dashboard.yaml
```

**Trilio Pods Monitor Dashboard** (kube-state-metrics — pod/container/resource detail):
```bash
oc create configmap trilio-pods-monitor-dashboard \
  --from-file=dashboard.json=grafana/TrilioPodsMonitorDashboard.json \
  -n openshift-user-workload-monitoring
oc apply -f grafana/grafana-trilio-pods-monitor-dashboard.yaml
```

The Pods Monitor dashboard requires kube-state-metrics to be running (step 2 above). It monitors all pods matching `triliovault-.*` in the selected namespace and shows:
- Deployment availability ratios (Online / Degraded / Offline)
- Pod phase counts (Running / Pending / Failed)
- Deployment replica status table (Desired / Available / Unavailable / Ready)
- Datamover DaemonSet coverage (Ready / Desired / Unavailable / Misscheduled)
- Per-pod phase and restart count inventory
- Per-container ready status and restart counts
- Container restart rate over time (time series)
- Pods in error/waiting state (CrashLoopBackOff, OOMKilled, ImagePullBackOff, etc.)
- Container CPU and memory requests/limits table

The `PROMETHEUS_TOKEN` in the Grafana secret must be a valid bearer token with access to the Thanos Querier.

## Key Conventions

- **Namespace**: All resources land in `openshift-user-workload-monitoring`. Never apply to a different namespace without verifying the ServiceMonitor selector matches.
- **Secrets are not checked in**: `grafana-secret-creds_original.yaml` is a template; actual credentials must be base64-encoded before applying.
- **sql-exporter config substitution**: The `data_source_name` in `sql-exporter-config.yaml` uses `$DB_USER_NAME`, `$DB_PASSWORD`, and `DB_HOST_NAME` (note: `DB_HOST_NAME` has no `$` — this is intentional, it relies on the DSN env var from the secret).
- **openstack-exporter clouds.yaml**: Uses `${VAR}` shell-style placeholders that must be substituted with `envsubst` or manually before `oc apply`.
- **ServiceMonitor scrape interval**: All exporters use 30s. Changing this also requires updating Prometheus retention or alerting rules if any exist.
- **rabbitmq-exporter vhost filter**: `INCLUDE_VHOST=^(workloadmgr|dmapi)$` anchors the regex so only Trilio vhosts are scraped. Adjust if vhost names change.
- **rabbitmq-exporter credentials**: The secret is not checked in with real values. Use `envsubst < rabbitmq-exporter-secret.yaml | oc apply -f -` to inject credentials at deploy time.
