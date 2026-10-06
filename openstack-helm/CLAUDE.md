# OpenStack Helm Deployment Scripts

## Overview
Helm charts for deploying TrilioVault (T4O) on OpenStack Helm and MOSK (Mirantis OpenStack for Kubernetes) platforms.
T4O is deployed as a single Helm release (`trilio-openstack`) that creates all required Kubernetes workloads, jobs, and config maps.

## Supported Versions
| Platform | OpenStack Release | values override |
|----------|------------------|-----------------|
| OpenStack Helm | Antelope, Bobcat, Epoxy | `2023.x.yaml` etc. |
| MOSK 22.x | Victoria, Yoga | `mosk22.*.yaml` |
| MOSK 25.1 | Caracal | `mosk25.1.yaml` |
| MOSK 26.2 | Gazpacho only | `mosk26.2.yaml` + `ingress_mosk.yaml` |

## MOSK 26.2 (Gazpacho) — TVAULT-7745
- **MOSK 26.2 support is opt-in files only. Every existing script, `values.yaml` and `Chart.yaml` is unchanged**, so OpenStack-Helm and MOSK ≤ 25.1 renders are identical to before. The new files are:
  - `values_overrides/mosk26.2.yaml`
  - `values_overrides/ingress_mosk.yaml`
  - `values_overrides/app_gateway.yaml` and `templates/httproute-{wlm,datamover}-api.yaml`
  - `docker/openstack-helm/trilio-horizon-plugin/Dockerfile_mosk26.2`
- **Installing:** operators hand-edit `utils/install_mosk.sh` before every install, as for earlier MOSK releases. For 26.2, change `mosk25.1.yaml` to `mosk26.2.yaml` and `ingress.yaml` to `app_gateway.yaml` (`ingress_mosk.yaml` only for a cloud not yet migrated to Application Gateway). Don't add a `*_26.2.sh` script and don't commit the edit; the other MOSK utils are reused as they are.
- **Only Gazpacho is qualified on 26.2.** MOSK 26.2 dropped Caracal and offers Gazpacho and Epoxy. Host nodes must be Ubuntu 24.04.
- **The 22.04 (`mosk25.1`) T4O images are reused unchanged** for WLM, datamover, DMAPI and DMS, so `mosk26.2.yaml` has the same tags as `mosk25.1.yaml`. Why this works:
  - The containers bring their own userspace, so the host OS doesn't matter.
  - The datamover (Caracal `python3-nova` 29.2) uses nova `Instance` 2.8 and `BlockDeviceMapping` 1.21, the same object versions as Gazpacho.
  - The datamover registers its own service record, not a nova-compute one, so Gazpacho's "oldest supported service = Epoxy" check doesn't apply to it.
  - The images' Ceph Reef 18.2 client is two releases behind the cluster's Tentacle 20.2, which Ceph supports.
- **Only the Horizon plugin is rebuilt**, on the MOSK Gazpacho Horizon image. Build it with the unchanged `devops-build-publish.sh <tag> mosk26.2`: containers without a `Dockerfile_mosk26.2` are skipped. Pulling the base image needs `mirantis.azurecr.io` credentials.
- **The qualified path is Gateway API (`app_gateway.yaml`).** MOSK 26.2 replaces NGINX Ingress with *Application Gateway* (Envoy Gateway, `Gateway` `openstack/app-gateway`), and a migrated cloud has **no IngressClass at all** (OsDpl `spec.migration.ingress.state: absent`), so Ingress objects would never be served. `app_gateway.yaml` turns on `templates/httproute-{wlm,datamover}-api.yaml` and turns off the Ingress / service_ingress / ingress TLS secret manifests. `values.yaml` declares `manifests.httproute_*: false` and the `network.*.http_route` defaults, so the default render is unaffected; `app_gateway.yaml` turns them on. On the lab, `app-gateway`'s HTTPS listener allowed routes from `All` namespaces (no ReferenceGrant, `sectionName` null) and its `*.<public_domain>` certificate covered our hostnames.
- **`ingress_mosk.yaml` is an untested fallback** for 26.2 clouds still on NGINX Ingress. It sets the class to `openstack-ingress-nginx`; the shared `ingress.yaml` keeps `nginx` for plain OpenStack-Helm.
- **The public domain must be the OsDpl `public_domain_name`** passed to `get_admin_creds_mosk.sh`. A wrong one (e.g. `triliodata.demo` instead of `setup2.triliodata.demo`) still installs, routes are Accepted and curl returns 200, but Keystone gets T4O public endpoints the gateway certificate doesn't cover, so TLS-verifying clients fail. Fix by reinstalling; a `helm upgrade` would trip over the immutable ks-* Jobs.
- **Inside T4O pods, use the internal Keystone endpoint for CLI work.** WLM pods are `hostNetwork` with `dnsPolicy: ClusterFirstWithHostNet`, so DNS goes to CoreDNS, which normally can't resolve the public `*.<public_domain>` names. A Horizon-downloaded openrc (`OS_AUTH_URL=https://keystone.<public_domain>/`, `OS_INTERFACE=public`) fails with `Name or service not known`; override with `OS_AUTH_URL=http://keystone-api.openstack.svc.<internal_domain>:5000/v3` and `OS_INTERFACE=internal`. The T4O services themselves already use the internal endpoint.
- **Horizon plugin on MOSK 26.2:**
  - The Gazpacho Horizon venv ships setuptools 84, and setuptools 82.0.0 removed `pkg_resources`, which `trilio_dashboard/workloadmgr.py` still imports. Without the `setuptools<82` pin in `Dockerfile_mosk26.2`, Horizon's startup `compress` step dies with `ModuleNotFoundError: pkg_resources` and the new pod crash-loops (old pods keep serving). The real fix belongs in `tvault-horizon-plugin` (use `importlib.metadata`).
  - Nodes run containerd and aren't reachable over SSH from the management host, so the guide's `ssh` + `docker pull` step doesn't work. Pre-pull with a short-lived DaemonSet on `openstack-control-plane=enabled` nodes using the `triliovault-image-registry` secret, then merge-patch the OsDpl image override. Use a new tag per rebuild (`IfNotPresent`).
- **A QGA freeze warning on a snapshot is expected for images without `hw_qemu_guest_agent=yes`.** libvirt answers `QEMU guest agent is not configured`; with `fail_on_qga_freeze_failure = false` the snapshot completes crash-consistent. The datamover's `greenlet.error: cannot switch to a different thread` lines during transfer-progress polling are noise from the unchanged 25.1 image; the transfer still completes.
- **Keep the vendored helm-toolkit at 2024.2.0.** Upstream helm-toolkit 2026.1.x removed the ingress helpers (`manifests.ingress`, `service_ingress`, `secret_ingress_tls`) that `templates/ingress-*.yaml` use.
- **`utils/create_rabbitmq.sh` pins the RabbitMQ cluster-operator to v2.21.1. Don't change it back to `latest`.**
  - From v2.22.0 (2026-07-01), the operator's admission webhooks get their TLS certificate from cert-manager (`Certificate cluster-operator-serving-cert` → secret `cluster-operator-webhook-server-cert`). Without cert-manager, the operator pod sticks in `ContainerCreating` with `FailedMount`. MOSK has no cert-manager.
  - v2.22.0 also switched to an HTTP startup probe that needs RabbitMQ ≥ 4.2.4, and our `RabbitmqCluster` runs `rabbitmq:3.13.3-management`.
  - Recovering from a failed newer install: `kubectl delete -f` with that release's manifest, so the dangling webhook configurations go too, then re-run the script.
- **`sync_nova_compute.sh` can only be run once per checkout.** `get_admin_creds_mosk.sh` calls it, and it consumes the `<INJECT_*>` placeholders in `templates/bin/`. Before re-running, restore them with `git checkout -- templates/bin/`.

## Directory Structure

```
openstack-helm/
├── Makefile                          # Build targets (lint, package, test)
├── charts/
│   ├── helm-toolkit/                 # Upstream OpenStack Helm shared library
│   │   └── templates/
│   │       ├── endpoints/            # Endpoint lookup helpers (_.tpl)
│   │       ├── manifests/            # Reusable K8s resource generators (_.tpl)
│   │       │   ├── _job-db-*.tpl     # Database init/sync jobs
│   │       │   ├── _job-ks-*.tpl     # Keystone registration jobs
│   │       │   └── _job-rabbit-init.yaml.tpl
│   │       ├── scripts/              # Shell script templates for jobs
│   │       ├── snippets/             # Reusable pod/container config snippets
│   │       └── utils/                # Template utilities (_to_oslo_conf.tpl, etc.)
│   │
│   └── trilio-openstack/             # TrilioVault Helm chart
│       ├── Chart.yaml                # Chart metadata and version
│       ├── values.yaml               # Default values — primary config reference
│       ├── templates/                # Kubernetes resource templates
│       │   └── bin/                  # Init script templates for jobs/pods
│       │       ├── _triliovault-cloudrc.tpl
│       │       ├── _triliovault-ceph.conf.tpl
│       │       └── (other init scripts)
│       ├── values_overrides/         # Platform-specific value files
│       │   ├── conf_triliovault.yaml # T4O service configuration
│       │   ├── admin_creds.yaml      # Keystone admin credentials (generated)
│       │   ├── ceph.yaml             # Ceph backend override
│       │   ├── tls_public_endpoint.yaml
│       │   └── victoria-ubuntu_focal.yaml
│       ├── files/                    # Static files (e.g., s3-cert.pem)
│       └── utils/                    # Deployment utility scripts
│           ├── install.sh            # Main Helm install entry point
│           ├── uninstall.sh
│           ├── get_admin_creds.sh    # Extract Keystone admin credentials
│           ├── get_ceph.sh           # Extract Ceph cluster config
│           └── create_image_pull_secret.sh
```

## Technology Stack
- **Helm 3**: Kubernetes package manager; all resources are Helm templates
- **Kubernetes**: Deployments, Jobs, ConfigMaps, Secrets, Services, Ingresses
- **Go templates / Sprig**: Helm's templating engine (same `.tpl` extension as Jinja2 but different syntax)
- **helm-toolkit**: Shared OpenStack Helm library providing reusable template fragments
- **oslo.conf**: OpenStack config file format generated by `_to_oslo_conf.tpl`

## DMS runtime directory (/run/dms) — TVAULT-7655
- **`/run` must be a `hostPath` in every DMS workload, mounted into the DMS server container itself — not just into the init container.** `/run/dms` holds the s3vaultfuse pid and lock files, and the FUSE mounts they describe live on the node under the `trilio-mounts` `hostPath` with `mountPropagation: Bidirectional`, so they outlive the pod. If `/run/dms` is pod-scoped, a pod restart loses the pid files while the mounts stay live on the node, and the DMS server's startup reconciliation cannot find them — they orphan silently. `daemonset-dms-compute.yaml` always had this right; `deployment-dms-controller.yaml` did not: its `run` volume was an `emptyDir` mounted **only** in `dms-init`, so the init container's `mkdir`/`chown` had no effect on anything the server could see. On the 6.2 images, which still baked `/run/dms` in, the server fell back to that pod-local writable overlay — working, but losing every pid file on a pod restart. With the tree removed from the image it would instead fail outright (`Permission denied: '/run/dms'`, uid 42424 under a root-owned container `/run`), so the template and the image change have to ship together.
- **The DMS images deliberately do NOT create `/run/dms`.** The root `dms-init` init container (`bin/_triliovault-dms-init.sh.tpl`, `runAsUser: 0`) creates and chowns `/run/dms/{s3,locks}` on every pod start, which is the correct primitive here — init containers re-run, so a node reboot self-heals the `/run` tmpfs. Do not remove that `mkdir`/`chown`, and do not re-add the tree to the image: with a `hostPath` `/run` mounted over it, an image tree is masked and only misleads whoever inspects the image. The Ansible-based distros (kolla-ansible, RHOSO18 data plane) have no root init step and use `/etc/tmpfiles.d/trilio-dms.conf` instead.
- **Never build from `openstack-helm/build/`.** `openstack-helm/.gitignore` ignores `build`, so that whole tree — including its own `build_containers.sh`, `publish_containers.sh` and `devops-build-publish.sh` — is an untracked local copy that has already silently diverged from the tracked source. The build tooling and Dockerfiles that ship are `docker/openstack-helm/`.
- **The helm nova uid is 42424, not 42436.** The init script hardcodes `chown -R 42424:42424`; kolla-ansible and RHOSO18 use 42436. Don't copy uid values between distros.

## Key Conventions

### Template File Extensions
- `.tpl` — Helm named template (partial), included via `{{ include "helm-toolkit.xxx" . }}`
- `.yaml` — full Kubernetes manifest template rendered by Helm

### values.yaml Layout
`values.yaml` is the single source of truth for defaults. It is structured by concern:
- `images:` — container image references per component
- `endpoints:` — service endpoint URLs and port definitions
- `conf:` — T4O config file content (maps directly to oslo.conf sections)
- `pod:` — replica counts, resource limits, affinity rules
- `dependencies:` — job dependency ordering

Always override via `values_overrides/` files rather than editing `values.yaml` directly.

### Deployment Flow
1. Run `utils/get_admin_creds.sh` → produces `values_overrides/admin_creds.yaml`
2. Run `utils/get_ceph.sh` → produces `values_overrides/ceph.yaml` (if Ceph backend)
3. Run `utils/create_image_pull_secret.sh` → registry credentials
4. Run `utils/install.sh` with the appropriate override files:
   ```
   helm install trilio-openstack charts/trilio-openstack \
     -f values_overrides/conf_triliovault.yaml \
     -f values_overrides/admin_creds.yaml \
     [-f values_overrides/ceph.yaml]
   ```

### helm-toolkit Usage
Never duplicate boilerplate Kubernetes YAML. Use the library helpers:
- `helm-toolkit.manifests.job_db_init` — database initialisation job
- `helm-toolkit.manifests.job_ks_service` — Keystone service registration
- `helm-toolkit.manifests.job_ks_endpoints` — Keystone endpoint registration
- `helm-toolkit.utils.to_oslo_conf` — render a `values.yaml` section as oslo.conf
- `helm-toolkit.endpoints.*` — resolve endpoint URLs from `values.endpoints`

### Adding a New Config Option
1. Add the default value under `conf:` in `values.yaml`
2. The `_to_oslo_conf.tpl` utility automatically renders it into the config map — no template changes needed unless the section is entirely new.
