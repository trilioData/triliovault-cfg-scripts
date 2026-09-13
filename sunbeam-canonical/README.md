# TrilioVault for Sunbeam Canonical OpenStack

Deploy TrilioVault for OpenStack (T4O) on [Sunbeam Canonical OpenStack](https://ubuntu.com/openstack/docs/sunbeam).
Targets **Caracal (OpenStack 2024.1)**.

## Architecture

Sunbeam runs OpenStack control plane services as Juju k8s charms in a MicroK8s cluster (the `openstack` model), and compute services as Juju machine charms on bare-metal nodes (the `openstack-machines` model).

TrilioVault maps onto this cleanly:

| T4O Component | Sunbeam Model | Charm |
|---------------|--------------|-------|
| WorkloadManager (wlm-api, wlm-workloads, wlm-cron, wlm-scheduler) + embedded DMS sidecar | `openstack` (k8s) | `trilio-wlm-k8s` |
| DataMover API (dmapi) | `openstack` (k8s) | `trilio-dm-api-k8s` |
| DataMover + DMS (compute side) | `openstack-machines` (machine) | `trilio-data-mover-sunbeam` |
| Horizon Plugin | `openstack` (k8s) | OCI image attach to `horizon` |

Dynamic Mount Service (DMS) is not a separate charm/application. The control-plane DMS instance runs as a second container (`trilio-dms`) co-located inside every `trilio-wlm-k8s` pod, one DMS instance per WLM replica.

`trilio-data-mover-sunbeam` is a **Juju subordinate charm** targeting `openstack-hypervisor`.
It installs both `tvault-contego` (DataMover) and `trilio-dms-server` (compute-side DMS) on every compute node.
When a new compute node joins via `sunbeam cluster join`, Juju automatically deploys a DataMover unit on it — no manual operator action required.

## Prerequisites

- Sunbeam bootstrap complete; `openstack` and `openstack-machines` models are healthy
- `juju` CLI installed and logged in to the Sunbeam controller
- NFS share or S3 bucket available for TrilioVault backup storage

## Install

Both bundles declare **Trilio applications only**. Every relation to one of Sunbeam's own
applications, and every cross-model offer, is added by `deploy_trilio.py`, which is the
supported way to install. Do not run `juju deploy ./trilio-*-bundle.yaml` by hand — the
bundle alone leaves the applications with no relations.

`deploy_trilio.py` is idempotent: deploys, offers, consumes and relations are each skipped
if they already exist, so it is safe to re-run after fixing a problem.

### Step 1 — Clone

```bash
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/sunbeam-canonical
```

The script resolves the `openstack` and `openstack-machines` models itself, including the
owner prefix Juju requires, so no `juju switch` is needed.

### Step 2 — Deploy control plane (k8s model)

```bash
./deploy_trilio.py ctlplane
```

This deploys `trilio-wlm-k8s`, `trilio-dm-api-k8s` and TrilioVault's own database cluster
`trilio-mysql`; relates them to `rabbitmq`, `keystone` (including the CA certificate
distribution Keystone TLS needs), `traefik` and `traefik-public`; creates the three offers
the data plane consumes; and then waits for every application to report `active`.

**TrilioVault always deploys its own `trilio-mysql` (mysql-k8s) cluster** rather than using
Sunbeam's database. Sunbeam's shared `mysql` application only exists in a `single`-topology
cloud; a `multi`-topology cloud has a per-service `<service>-mysql` for each OpenStack
service and no application named `mysql` at all. Its connection and memory limits are also
computed from a service list that does not include TrilioVault.

`trilio-mysql` gets the same storage pool and volume size the cloud gives its own OpenStack
database clusters, and memory and connection limits from the same formula Sunbeam uses.
Both storage settings can be overridden:

```bash
./deploy_trilio.py ctlplane --db-storage=50G
./deploy_trilio.py ctlplane --db-storage-pool=<pool>
```

The storage pool is what selects the Kubernetes storage class. Create one with:

```bash
juju create-storage-pool <pool> kubernetes storage-class=<storage class>
```

Other options: `--no-wait` returns as soon as everything is wired instead of waiting for
active, `--timeout=<seconds>` changes how long the wait allows (default 1800).

**Verify:**

```bash
juju status trilio-wlm-k8s trilio-dm-api-k8s trilio-mysql
kubectl get pods -n openstack | grep trilio
```

### Step 3 — Deploy data plane (machine model)

```bash
./deploy_trilio.py dataplane
```

This consumes the `rabbitmq`, `keystone-credentials` and `cert-distributor` offers created
in step 2, deploys the `trilio-data-mover` subordinate, and relates it to
`openstack-hypervisor`, the consumed offers, and `microceph` when the cloud has it.

**Verify:**

```bash
juju status trilio-data-mover -m openstack-machines
```

`./deploy_trilio.py all` runs both steps in order.

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

An upgrade refreshes the Trilio charms only. `trilio-mysql` is not refreshed by
`deploy_trilio.py` and is not touched by any of the steps below — its volumes hold the
TrilioVault metadata and are never reused, reformatted or destroyed by these scripts.


### Step 1 — Upgrade control plane

```bash
juju switch openstack
juju refresh trilio-wlm-k8s    --channel latest/candidate
juju refresh trilio-dm-api-k8s --channel latest/candidate
```

**Verify:**

```bash
juju wait-for application trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju status trilio-wlm-k8s trilio-dm-api-k8s
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
| `trilio-wlm-k8s` | `charms/trilio-wlm-k8s/` | k8s, Pebble — includes embedded `trilio-dms` sidecar container (control plane DMS server) |
| `trilio-dm-api-k8s` | `charms/trilio-dm-api-k8s/` | k8s, Pebble |
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
| `docker.io/trilio/trilio-horizon-plugin-canonical` | `sunbeam-canonical/docker/trilio-horizon-plugin/Dockerfile_2024.1` | `horizon` attach-resource |

Build and publish all images:

```bash
cd sunbeam-canonical/docker
bash devops-build-publish.sh \
  --tag 6.2.1-2024.1 \
  --containers all \
  --mode build-and-publish
```
