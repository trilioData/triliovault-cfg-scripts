# Trilio (T4O) backup monitoring on Canonical Observability Stack (COS)

COS port of `redhat-director-scripts/monitoring-openshift`. It shows the same
"Trilio Openstack Backup Monitor T4O" Grafana dashboard: snapshots, restores,
protected VMs, backup size and quota usage, per project and per cloud.

## Architecture

```
 OpenStack model (Juju 2.9, MAAS)                     COS model (Juju 3.x, MicroK8s)
 ---------------------------------                    -------------------------------
 trilio-wlm leader unit
   mysql-router 127.0.0.1:3306 --> workloadmgr DB
   trilio-sql-exporter :9399  <--------- scrape ----- trilio-sql-exporter
     (systemd, sql_exporter)                           (prometheus-scrape-target-k8s)
                                                              |
 openstack-exporter (charm) --cos-agent--> grafana-agent      v
   keystone:identity-admin                   |  remote-write  prometheus --> grafana
                                             +--------------> (Trilio dashboard
                                                               imported via API)
```

| OpenShift (`monitoring-openshift`)  | COS (`monitoring-cos`)                                          |
|-------------------------------------|-----------------------------------------------------------------|
| `sql_exporter/` Deployment + ConfigMap | `sql_exporter/` systemd service on the trilio-wlm leader unit |
| sql-exporter `ServiceMonitor`       | `prometheus-scrape-target-k8s` app in the COS model             |
| `openstack_exporter/` Deployment    | `openstack-exporter` charm related to keystone and grafana-agent |
| `grafana/` GrafanaDashboard         | `grafana/TrilioGrafanaDashboard.json` imported with the Grafana API |

Metrics used by the dashboard:

| Source             | Metrics |
|--------------------|---------|
| sql_exporter       | `mysql_trilio_snapshots_info`, `mysql_trilio_restore_info`, `mysql_trilio_snapshots_status`, `mysql_trilio_backup_size_info`, `mysql_trilio_restore_size_info`, `mysql_trilio_snapshot_last_updated`, `mysql_trilio_restore_last_updated`, `openstack_protected_vm`, `openstack_protected_vm_total`, `trilio_allowed_quota_value`, `trilio_quota_high_watermark`, `trilio_workload_info`, `trilio_workload_vm_info` |
| openstack-exporter | `openstack_identity_domain_info` / `openstack_identity_project_info` (Domain and Project drop-downs), `openstack_nova_server_status` (protected vs. unprotected instances) |

The sql_exporter collectors are the same as the OpenShift ConfigMap
(`monitoring-openshift/sql_exporter/sql-exporter-config.yaml`). Only the DSN
differs: deploy.sh renders it on the unit.

`grafana/TrilioGrafanaDashboard.json` is generated from the OpenShift dashboard
by `grafana/convert_openshift_dashboard.py`. The script makes these changes:

- Every panel and variable uses the `$datasource` variable. COS names its
  Prometheus datasource after the Juju topology, so there is no fixed
  datasource UID to point at.
- A **Domain** selector (from `openstack_identity_domain_info`) comes before
  **Project Name**. Charmed OpenStack has `admin` and `services` projects in
  more than one domain, so a project name alone can resolve to the wrong
  project ID. `service_domain` and the `service`/`services` projects are hidden.
- The cloud-level "Protected instance info" panel uses
  `sum(openstack_protected_vm_total)`. That metric counts a VM protected under
  several projects only once.
- Tables hide any `juju_*` topology labels.

When the OpenShift dashboard or sql_exporter config changes, sync both into COS:

```bash
python3 grafana/convert_openshift_dashboard.py \
    ../../redhat-director-scripts/monitoring-openshift/grafana/TrilioGrafanaDashboard.json \
    grafana/TrilioGrafanaDashboard.json
# copy the collectors from sql-exporter-config.yaml into sql_exporter/sql_exporter.yml
./deploy.sh sql-exporter && ./deploy.sh dashboard
```

The Snapshot pie charts and the Failed Snapshots/Failed Restores tables only
count snapshots and restores whose last status change falls inside the
dashboard time range (default: last 3 hours). Widen the range to see older
ones. Restore and quota panels show "No data"/NaN until there are restores,
or until Trilio project quotas are set.

## Prerequisites

- COS deployed with `prometheus`, `grafana` and the `grafana-dashboards` and
  `prometheus-receive-remote-write` offers.
- `grafana-agent` deployed in the OpenStack model and consuming those offers.
- A host with both Juju clients: `juju` (2.9, OpenStack controller) and
  `juju_juju3` (3.x, COS controller).
- Internet access, or a proxy, from the trilio-wlm unit to GitHub (sql_exporter
  release) and from the openstack-exporter unit to the Snap Store.
- The COS Prometheus pod must reach the trilio-wlm unit on TCP 9399.

## Deploy

Copy this directory to the jump host and run:

```bash
GRAFANA_URL=http://<cos-ingress-ip-or-host>/cos-grafana \
PROMETHEUS_URL=http://<cos-ingress-ip-or-host>/cos-prometheus-0 \
./deploy.sh all
```

Replace `<cos-ingress-ip-or-host>` with the IP or hostname your COS model's
ingress/traefik is reachable on (find it with `juju_juju3 run traefik/leader
show-proxied-endpoints -m "${COS_MODEL}"`).

`all` runs these steps in order. Each step can also be run on its own and is
safe to re-run:

| Step                 | What it does |
|----------------------|--------------|
| `sql-exporter`       | Installs sql_exporter on the trilio-wlm leader as `trilio-sql-exporter.service`. The DSN comes from `sql_connection` in `/etc/triliovault-wlm/triliovault-wlm.conf` and goes through the unit's local mysql-router. It is written to `/etc/sql_exporter/sql_exporter.yml` (mode 0640) and never printed. |
| `openstack-exporter` | Deploys the `openstack-exporter` charm into an LXD container on the trilio-wlm host machine, sets `ssl_ca` from the Vault root CA, and relates it to `keystone:identity-admin` and `grafana-agent:cos-agent`. |
| `scrape-target`      | Deploys `prometheus-scrape-target-k8s` as `trilio-sql-exporter` in the COS model, points it at `<wlm-leader-ip>:9399` and integrates it with `prometheus:metrics-endpoint`. |
| `dashboard`          | Imports `grafana/TrilioGrafanaDashboard.json` into COS Grafana (uid `trilio-t4o-cos`) and overwrites any earlier copy. |
| `verify`             | Shows exporter, charm and Prometheus status. With `PROMETHEUS_URL` set, it also queries Prometheus for each metric family. |

If `GRAFANA_URL` or `GRAFANA_PASSWORD` is unset, the script uses the grafana
charm's `get-admin-password` action to get it.

### Settings (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `OS_MODEL` | current model | OpenStack model, e.g. `maas-controller:admin/openstack` |
| `WLM_APP` | `trilio-wlm` | |
| `OSE_TO` | `lxd:<wlm host machine>` | Placement for openstack-exporter |
| `OSE_CHANNEL` / `OSE_SERIES` | `latest/stable` / `jammy` | The jammy build is rev 77; noble builds are rev 78 and later |
| `SQL_EXPORTER_VERSION` | `0.24.10` | burningalchemist/sql_exporter release |
| `COS_MODEL` | `cos-controller:admin/cos` | |
| `SCRAPE_CHANNEL` | `1/stable` | prometheus-scrape-target-k8s channel |
| `JUJU` / `JUJU3` | `juju` / `juju_juju3` | Juju 2.9 and 3.x CLIs |

## Notes

- **trilio-wlm leadership:** sql_exporter runs only on the trilio-wlm leader.
  This avoids duplicate series when there are several wlm units. If leadership
  moves, run `./deploy.sh sql-exporter` and `./deploy.sh scrape-target` again.
- **DB user:** the exporter reuses the workloadmgr DB user and runs only
  `SELECT` queries. To use a dedicated read-only user, create one with
  `GRANT SELECT ON workloadmgr.*` and edit the DSN in
  `/etc/sql_exporter/sql_exporter.yml` on the unit.
- **openstack-exporter charm:** it also forwards its own OpenStack dashboards
  and alert rules to COS through grafana-agent.
- **Removal:**

  ```bash
  juju ssh trilio-wlm/leader 'sudo systemctl disable --now trilio-sql-exporter'
  juju remove-application openstack-exporter
  juju_juju3 remove-application -m cos-controller:admin/cos trilio-sql-exporter
  ```

  Then delete the dashboard in Grafana.
