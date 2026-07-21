# TrilioVault for Sunbeam Canonical OpenStack

Deploy TrilioVault for OpenStack (T4O) on [Sunbeam Canonical OpenStack](https://ubuntu.com/openstack/docs/sunbeam).
Targets **Caracal (OpenStack 2024.1)**.

## Architecture

Sunbeam runs OpenStack control plane services as Juju k8s charms in a MicroK8s cluster (the `openstack` model), and compute services as Juju machine charms on bare-metal nodes (the `openstack-machines` model).

TrilioVault maps onto this cleanly:

| T4O Component | Sunbeam Model | Charm |
|---------------|--------------|-------|
| WorkloadManager (wlm-api, wlm-workloads, wlm-cron, wlm-scheduler) | `openstack` (k8s) | `trilio-wlm-k8s` |
| DataMover API (dmapi) | `openstack` (k8s) | `trilio-dm-api-k8s` |
| Dynamic Mount Service — control plane | `openstack` (k8s) | `trilio-dms-k8s` |
| DataMover + DMS (compute side) | `openstack-machines` (machine) | `trilio-data-mover-sunbeam` |
| Horizon Plugin | `openstack` (k8s) | OCI image attach to `horizon` |

`trilio-data-mover-sunbeam` is a **Juju subordinate charm** targeting `openstack-hypervisor`.
It installs both `tvault-contego` (DataMover) and `trilio-dms-server` (compute-side DMS) on every compute node.
When a new compute node joins via `sunbeam cluster join`, Juju automatically deploys a DataMover unit on it — no manual operator action required.

## Prerequisites

- Sunbeam bootstrap complete; `openstack` and `openstack-machines` models are healthy
- `juju` CLI installed and logged in to the Sunbeam controller
- NFS share or S3 bucket available for TrilioVault backup storage

## Install

### Step 1 — Verify cross-model offers

Sunbeam creates RabbitMQ and Keystone offers by default. Verify they exist:

```bash
juju find-offers --format=tabular | grep -E 'rabbitmq|keystone-credentials'
```

If missing, create them:

```bash
juju switch openstack
juju offer rabbitmq:amqp
juju offer keystone:identity-credentials
```

### Step 2 — Deploy control plane (k8s model)

```bash
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/sunbeam-canonical

juju switch openstack
juju deploy ./trilio-ctlplane-bundle.yaml
```

All relations — including CA certificate distribution for Keystone TLS — are included in the bundle.

**Verify:**

```bash
juju wait-for application trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju wait-for application trilio-dms-k8s    --query='status=="active"' --timeout=10m
juju status trilio-wlm-k8s trilio-dm-api-k8s trilio-dms-k8s
kubectl get pods -n openstack | grep trilio
```

### Step 3 — Deploy data plane (machine model)

```bash
juju switch openstack-machines
juju deploy ./trilio-dataplane-bundle.yaml
```

Cross-model RabbitMQ and Keystone relations are declared in the bundle's `saas:` section.

**Verify:**

```bash
juju wait-for application trilio-data-mover --query='status=="active"' --timeout=10m
juju status trilio-data-mover
```

### Step 4 — Attach Horizon Plugin

```bash
juju attach-resource horizon \
  horizon-image=docker.io/trilio/trilio-horizon-plugin-canonical:shyam-tv7404-12 \
  -m openstack
```

**Verify:**

```bash
kubectl exec -n openstack horizon-0 -c horizon -- \
  python3 -c 'import trilio_dashboard; print(trilio_dashboard.__file__)'
```

### Step 5 — Post-install: Cloud Admin Trust and License

```bash
juju switch openstack
juju run trilio-wlm-k8s/leader create-cloud-admin-trust \
  password=<cloud-admin-password>

juju attach-resource trilio-wlm-k8s license=<path-to-license-file>
juju run trilio-wlm-k8s/leader create-license
```

## Upgrade

### Step 1 — Upgrade control plane

```bash
juju switch openstack
juju refresh trilio-wlm-k8s    --channel latest/candidate
juju refresh trilio-dm-api-k8s --channel latest/candidate
juju refresh trilio-dms-k8s    --channel latest/candidate
```

**Verify:**

```bash
juju wait-for application trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju wait-for application trilio-dms-k8s    --query='status=="active"' --timeout=10m
juju status trilio-wlm-k8s trilio-dm-api-k8s trilio-dms-k8s
```

### Step 2 — Upgrade data plane

```bash
juju switch openstack-machines
juju config trilio-data-mover trilio-version=<new-version>
juju refresh trilio-data-mover --channel latest/candidate
```

**Verify:**

```bash
juju wait-for application trilio-data-mover --query='status=="active"' --timeout=10m
juju status trilio-data-mover
```

### Step 3 — Upgrade Horizon plugin

```bash
juju attach-resource horizon \
  horizon-image=docker.io/trilio/trilio-horizon-plugin-canonical:<new-tag> \
  -m openstack
```

**Verify:**

```bash
kubectl exec -n openstack horizon-0 -c horizon -- \
  python3 -c 'import trilio_dashboard; print(trilio_dashboard.__file__)'
```

## Charm Source Code

| Charm | Location | Notes |
|-------|----------|-------|
| `trilio-wlm-k8s` | `charms/trilio-wlm-k8s/` | k8s, Pebble |
| `trilio-dm-api-k8s` | `charms/trilio-dm-api-k8s/` | k8s, Pebble |
| `trilio-dms-k8s` | `charms/trilio-dms-k8s/` | k8s, Pebble — control plane DMS server |
| `trilio-data-mover-sunbeam` | `charms/trilio-data-mover-sunbeam/` | machine subordinate, runs DataMover + compute DMS |

## Build Prerequisites

To build OCI images or Juju charms, the build machine must have Docker and charmcraft installed.
A setup script is provided to prepare any Ubuntu machine in one step:

**Supported OS**: Ubuntu 22.04 LTS (Jammy) or 24.04 LTS (Noble).

```bash
# Run from the repository root — idempotent, safe to re-run
bash sunbeam-canonical/build/setup_build_machine.sh
```

What the script installs:
- Docker CE (from the official Docker APT repository) — required for OCI image builds
- `charmcraft` snap (`latest/stable` channel) — required for Juju charm builds
- Base dependencies: `git`, `curl`, `python3`, `snapd`

After the script completes:
1. Re-login or run `newgrp docker` so the `docker` group takes effect
2. `docker login` with your Docker Hub credentials
3. Export charmcraft credentials: `export CHARMCRAFT_AUTH=$(cat creds.txt)`
   (generate `creds.txt` with `charmcraft login --export creds.txt` on a machine with a browser)

---

## OCI Images

Dockerfiles are in `docker/`:

| Image | Dockerfile | Used by |
|-------|-----------|---------|
| `docker.io/trilio/trilio-wlm-canonical` | `sunbeam-canonical/docker/trilio-wlm/Dockerfile_2024.1` | `trilio-wlm-k8s` |
| `docker.io/trilio/trilio-datamover-api-canonical` | `sunbeam-canonical/docker/trilio-datamover-api/Dockerfile_2024.1` | `trilio-dm-api-k8s` |
| `docker.io/trilio/trilio-dms-canonical` | `sunbeam-canonical/docker/trilio-dms/Dockerfile` | `trilio-dms-k8s` |
| `docker.io/trilio/trilio-horizon-plugin-canonical` | `sunbeam-canonical/docker/trilio-horizon-plugin/Dockerfile_2024.1` | `horizon` attach-resource |

Build and publish all images:

```bash
cd sunbeam-canonical/docker
bash devops-build-publish.sh \
  --tag 6.2.1-2024.1 \
  --containers all \
  --mode build-and-publish
```
