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

### What gets installed

These scripts install **Trilio services only**. Sunbeam's own services — mysql, rabbitmq,
keystone, traefik, microceph, openstack-hypervisor — must already exist in your cloud and
are never deployed, refreshed or rescaled by Trilio. The deploy scripts only add relations
to them.

### Step 1 — Verify cross-model offers

The data plane reaches RabbitMQ and Keystone across models. Sunbeam creates these offers by
default; verify they exist:

```bash
juju offers -m openstack | grep -E 'rabbitmq|keystone-credentials|cert-distributor'
```

`rabbitmq` and `keystone-credentials` are required. If either is missing, create it:

```bash
juju switch openstack
juju offer rabbitmq:amqp rabbitmq
juju offer keystone:identity-credentials keystone-credentials
```

> **The trailing offer name is required, not cosmetic.** `juju offer <app>:<endpoint>` names
> the offer after the *application*, so `juju offer keystone:identity-credentials` alone
> creates an offer called `keystone` — which the deploy script will not find. Worse, both
> keystone offers would take that same default name and the second would overwrite the
> first, leaving you with neither.

`cert-distributor` (`keystone:send-ca-cert`) is **optional** and present on TLS-enabled
clouds. If it exists the deploy script wires CA distribution automatically; if not, it skips
that step. Create it only if your cloud uses TLS and it is missing:

```bash
juju offer keystone:send-ca-cert cert-distributor
```

You do not need to note the offer URLs — `deploy_dataplane.py` reads them itself, from the
control-plane model only (`juju offers -m openstack`). They are site-specific — they embed
your own controller, user and model — so nothing is hardcoded.

Scoping the lookup to one model is deliberate: offer names are unique *within* a model, not
across a controller, so a second Sunbeam cloud or a model left over from a re-bootstrap
cannot be picked up by mistake. If your control plane is not the `openstack` model, name it
with `--ctlplane-model`; to point at an individual offer elsewhere, use `--rabbitmq-offer`,
`--keystone-offer` or `--cert-offer`.

### Step 2 — Deploy control plane (k8s model)

```bash
git clone https://github.com/trilioData/triliovault-cfg-scripts.git
cd triliovault-cfg-scripts/sunbeam-canonical

./deploy_ctlplane.py
```

This deploys `trilio-wlm-k8s` and `trilio-dm-api-k8s` (with `--trust`, which both charms
require to patch their own StatefulSets for FUSE access) and then relates them to mysql,
rabbitmq, keystone, traefik and traefik-public, including CA certificate distribution for
Keystone TLS.

If your control-plane model is not named `openstack`, pass it explicitly:

```bash
./deploy_ctlplane.py -m controller0/openstack
```

**Verify:**

```bash
juju wait-for application -m openstack trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application -m openstack trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju status -m openstack trilio-wlm-k8s trilio-dm-api-k8s
kubectl get pods -n openstack | grep trilio
```

### Step 3 — Deploy data plane (machine model)

```bash
./deploy_dataplane.py
```

This deploys the `trilio-data-mover` subordinate, binds it to `openstack-hypervisor`,
consumes the RabbitMQ and Keystone offers, and adds two relations **conditionally**:

| Relation | Added when |
|---|---|
| `trilio-data-mover:receive-ca-cert` ↔ `cert-distributor:send-ca-cert` | the `cert-distributor` offer exists (TLS-enabled cloud) |
| `trilio-data-mover:ceph` ↔ `microceph:ceph` | `microceph` is deployed in the model |

Ceph is only needed where OpenStack itself uses Ceph — it gives the DataMover its own
credentials for direct `rbd` access to Ceph-backed Cinder volumes. On a cloud with
local/LVM storage the DataMover runs without it and the script skips the relation.

Use `-m` if your machine model is not named `openstack-machines`:

```bash
./deploy_dataplane.py -m admin/openstack-machines
```

**Verify:**

```bash
juju wait-for application -m openstack-machines trilio-data-mover --query='status=="active"' --timeout=10m
juju status -m openstack-machines trilio-data-mover
```

A DataMover unit appears on every `openstack-hypervisor` machine, including nodes that join
later via `sunbeam cluster join` — no action needed for new compute nodes.

### Step 4 — Attach the Trilio Horizon plugin

The Trilio dashboard plugin is **not** a separate application. It ships as a replacement for
Sunbeam's own `horizon` charm's `horizon-image` resource, so it is attached to that charm
rather than deployed. Re-attach it on every plugin image rebuild.

```bash
juju attach-resource -m openstack horizon \
  horizon-image=docker.io/trilio/trilio-horizon-plugin-canonical:6.2.1-maint-1-2024.1
```

This touches only the image — `horizon`'s charm revision and scale are left alone. That is
deliberate: declaring `horizon` in a bundle would make Trilio a desired-state authority over
a core Sunbeam application.

**Verify:**

```bash
kubectl exec -n openstack horizon-0 -c horizon -- \
  python3 -c 'import trilio_dashboard; print(trilio_dashboard.__file__)'
```

### Step 5 — Post-install: cloud admin trust and licence

Both actions run on the WLM **leader** unit, and the order matters — the trust must exist
before the licence is applied.

```bash
# 1. Cloud admin trust (WLM uses it to act on behalf of projects)
juju run -m openstack trilio-wlm-k8s/leader create-cloud-admin-trust \
  password=<cloud-admin-password>

# 2. Copy the licence file INTO the LEADER's workload container, then apply it by
#    its in-container path. The action checks for the file inside its own unit's
#    container, and with scale: 3 the leader is often /1 or /2 — never assume /0.
LEADER=$(juju status -m openstack trilio-wlm-k8s --format=json | python3 -c \
  'import json,sys; a=json.load(sys.stdin)["applications"]["trilio-wlm-k8s"]["units"]; \
   print(next(u for u,v in a.items() if v.get("leader")).replace("/","-"))')

kubectl cp <licence-file> openstack/$LEADER:/tmp/license -c trilio-wlm

juju run -m openstack trilio-wlm-k8s/leader create-license \
  license-file-path=/tmp/license
```

> **`juju attach-resource ... license=<file>` does not apply the licence.** The charm never
> reads that resource. `create-license` takes a *required* `license-file-path` parameter and
> checks for the file inside the `trilio-wlm` container **on the unit the action runs on** —
> see `charms/trilio-wlm-k8s/actions.yaml`. Running the action without the parameter fails
> with `required parameter license-file-path not specified`; copying to the wrong pod fails
> with a file-not-found even though the copy itself succeeded.

OpenStack credentials are read automatically from the identity-service relation, so the
action takes no password.

### Verify the install

```bash
juju status -m openstack          trilio-wlm-k8s trilio-dm-api-k8s
juju status -m openstack-machines trilio-data-mover
openstack endpoint list | grep -Ei 'workloads|datamover'
```

All Trilio applications should reach `active/idle`, a DataMover unit should be present on
every compute node, and both Trilio service endpoints should be registered in Keystone.

### Re-running the scripts

Both scripts are safe to re-run, and re-running is a normal operation rather than a repair of
last resort. A re-run never fails a working deployment: an already-deployed bundle, an
already-consumed offer and an already-existing relation are each skipped.

Re-run when you want to:

| Situation | What the re-run does |
|---|---|
| A relation is missing (removed by hand, or lost in a failed hook) | Adds just that relation |
| Ceph was enabled on the cloud after Trilio was installed | Adds `trilio-data-mover:ceph ↔ microceph:ceph` |
| TLS was enabled, so `cert-distributor` now exists | Consumes the offer and adds `receive-ca-cert` |
| An upgrade introduced a new relation the charm now needs | Adds the new relation |
| The bundle created one Trilio app and failed before the other | Re-applies the bundle to finish the job |

The conditional relations are re-evaluated against the live cloud on every run, which is what
makes the middle three rows work — nothing is remembered from the first install.

> **One caveat on the last row.** Re-applying a bundle is a desired-state operation, so the
> application that *did* deploy gets reconciled to the revision and image pinned in the
> bundle. That only ever touches applications Trilio owns — never a Sunbeam one — so it
> cannot repeat the TVAULT-7404 failure, but it does mean a partial re-run can move your own
> Trilio app onto the bundle's pins.

> **The scripts install; they do not upgrade.** Once *all* the Trilio applications exist, the
> bundle is skipped entirely — so bumping a charm revision or image tag and re-running will
> not move a deployed cloud onto it. Upgrade explicitly, with `juju refresh` (see
> [Upgrade](#upgrade) below).

## Upgrade

### Step 1 — Upgrade control plane

```bash
juju refresh -m openstack trilio-wlm-k8s --channel 6.2/candidate   --resource trilio-wlm-image=docker.io/trilio/trilio-wlm-canonical:<tag>

juju refresh -m openstack trilio-dm-api-k8s --channel 6.2/candidate   --resource trilio-dm-api-image=docker.io/trilio/trilio-datamover-api-canonical:<tag>
```

Pass `--resource` in the same command as the charm refresh, so the charm and its image move
together rather than triggering two separate pod cycles. Use the image tags recorded in
`trilio-ctlplane-bundle.yaml` for the release you are moving to.

**Verify:**

```bash
juju wait-for application -m openstack trilio-wlm-k8s    --query='status=="active"' --timeout=10m
juju wait-for application -m openstack trilio-dm-api-k8s --query='status=="active"' --timeout=10m
juju status -m openstack trilio-wlm-k8s trilio-dm-api-k8s
```

### Step 2 — Upgrade data plane

```bash
juju config -m openstack-machines trilio-data-mover trilio-version=<new-version>
juju refresh -m openstack-machines trilio-data-mover --channel 6.2/candidate
```

**Verify:**

```bash
juju wait-for application -m openstack-machines trilio-data-mover --query='status=="active"' --timeout=10m
juju status -m openstack-machines trilio-data-mover
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
