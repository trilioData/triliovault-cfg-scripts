# TrilioVault for Sunbeam Canonical OpenStack

Deploy TrilioVault for OpenStack (T4O) on [Sunbeam Canonical OpenStack](https://ubuntu.com/openstack/docs/sunbeam).

## Architecture

Sunbeam runs OpenStack control plane services as Juju k8s charms in a MicroK8s cluster (the `openstack` model), and compute services as Juju machine charms on bare-metal nodes (the `openstack-machines` model).

TrilioVault maps onto this cleanly:

| T4O Component | Sunbeam Model | Charm |
|---------------|--------------|-------|
| WorkloadManager (wlm-api, wlm-workloads, wlm-cron, wlm-scheduler) | `openstack` (k8s) | `trilio-wlm-k8s` |
| DataMover API (dmapi) | `openstack` (k8s) | `trilio-dmapi-k8s` |
| DataMover (tvault-contego) | `openstack-machines` (machine) | `trilio-data-mover-sunbeam` |
| Horizon Plugin | `openstack` (k8s) | OCI image attach to `horizon-k8s` |

`trilio-data-mover-sunbeam` is a **Juju subordinate charm** targeting `openstack-hypervisor`.  
When a new compute node joins via `sunbeam cluster join`, Juju automatically deploys a DataMover unit on it — no manual operator action required.

## Prerequisites

- Sunbeam bootstrap complete; `openstack` and `openstack-machines` models are healthy
- `juju` CLI installed and logged in to the Sunbeam controller
- NFS share or S3 bucket available for TrilioVault backup storage

## Quick Start — Install

```bash
# Clone or download this repo
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/sunbeam-canonical

# Install with NFS backup target
bash install.sh --nfs-shares 192.168.1.10:/backup --trilio-version 6.2.1
```

See `bash install.sh --help` for all options including S3 backup target.

## Quick Start — Upgrade

```bash
bash upgrade.sh --trilio-version 6.3.1
```

This upgrades all three T4O charms and updates the Horizon plugin OCI image.

## Manual Deployment

### 1. Control Plane (k8s model)

```bash
juju switch openstack

# Offer cross-model relations for data plane
juju offer rabbitmq:amqp
juju offer keystone:identity-credentials

# Deploy
juju deploy ./trilio-ctlplane-bundle.yaml
```

Configure NFS or S3 after deploy:

```bash
# NFS
juju config trilio-wlm-k8s backup-target-type=nfs nfs-shares=192.168.1.10:/backup

# S3
juju config trilio-wlm-k8s \
  backup-target-type=s3 \
  s3-access-key=<KEY> \
  s3-secret-key=<SECRET> \
  s3-bucket=<BUCKET> \
  s3-region=<REGION>
```

### 2. Data Plane (machine model)

```bash
juju switch openstack-machines
juju deploy ./trilio-dataplane-bundle.yaml \
  --config trilio-data-mover-sunbeam.nfs-shares=192.168.1.10:/backup
```

### 3. Horizon Plugin

Attach the Trilio Horizon OCI image to the `horizon-k8s` charm:

```bash
juju attach-resource horizon-k8s \
  horizon-image=docker.io/trilio/trilio-horizon-canonical:6.2.1 \
  -m openstack
```

Horizon reloads automatically — no restart required.

## Charm Source Code

| Charm | Location |
|-------|----------|
| `trilio-wlm-k8s` | `charms/charm-trilio-wlm-k8s/` |
| `trilio-dmapi-k8s` | `charms/charm-trilio-dmapi-k8s/` |
| `trilio-data-mover-sunbeam` | `charms/charm-trilio-data-mover-sunbeam/` |

## OCI Images

Dockerfiles are in `../docker/canonical/`:

| Image | Dockerfile |
|-------|-----------|
| `docker.io/trilio/trilio-wlm-canonical` | `docker/canonical/trilio-wlm/Dockerfile` |
| `docker.io/trilio/trilio-dmapi-canonical` | `docker/canonical/trilio-dmapi/Dockerfile` |
| `docker.io/trilio/trilio-horizon-canonical` | `docker/canonical/trilio-horizon-plugin/Dockerfile` |
