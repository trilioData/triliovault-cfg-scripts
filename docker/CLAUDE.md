# Docker Container Images

## Overview
Dockerfiles and supporting files for building TrilioVault (T4O) container images for each deployment platform.
Each platform (Kolla Ansible, OpenStack Helm / MOSK, RedHat TripleO/RHOSP) has its own set of images because base OS, package sources, and startup scripts differ between them.

## Directory Structure

```
docker/
├── kolla-ansible/                  # Images for Kolla Ansible deployments
│   ├── trilio-datamover-api/       # DMAPI service image
│   ├── trilio-datamover/           # DataMover service image
│   ├── trilio-horizon-plugin/      # Horizon UI plugin image
│   └── trilio-wlm/                 # WorkloadManager service image
│
├── openstack-helm/                 # Images for OpenStack Helm / MOSK deployments
│   ├── trilio-common/              # Shared base image (extended by other images)
│   ├── trilio-datamover-api/
│   ├── trilio-datamover/
│   ├── trilio-horizon-plugin/
│   └── trilio-wlm/
│
└── redhat-director-scripts/docker/ # Images for RHOSP 16, TripleO Train/Wallaby
    ├── trilio-datamover-api/
    ├── trilio-datamover/
    ├── trilio-horizon-plugin/
    └── trilio-wlm/
```

## Dockerfile Naming Convention

```
Dockerfile[_<platform>[_<version>]]
```

Examples:
| Filename | Platform / Version |
|----------|--------------------|
| `Dockerfile` | Generic / default |
| `Dockerfile_mosk22.3` | MOSK 22.3 |
| `Dockerfile_mosk22.4_yoga` | MOSK 22.4 with Yoga release |
| `Dockerfile_tripleo_wallaby_centos8s` | TripleO Wallaby on CentOS Stream 8 |
| `Dockerfile_rhosp16.1` | RHOSP 16.1 |
| `Dockerfile_victoria_ubuntu_focal` | Victoria on Ubuntu Focal |
| `Dockerfile_*-DEP` | Deprecated — do not use for new builds |

## Per-Component Files

### trilio-datamover
Key extra files beyond the Dockerfile:
- `start_datamover_nfs` — container entrypoint for NFS backup target
- `start_datamover_s3` — container entrypoint for S3 backup target
- `start_tvault_object_store` — container entrypoint for object store backend
- `nova-sudoers` — sudoers rules required for nova-compute integration
- `log-rotate-conf` — logrotate config baked into the image

### trilio-horizon-plugin
- `horizon_template_overrides.j2` — Kolla Horizon template overrides (kolla-ansible builds)
- `kolla-build.conf` — Kolla image build configuration
- `manage.py` — Django management helper (openstack-helm builds)

### trilio-wlm
- `log-rotate-conf` — logrotate config
- `test_container/` — lightweight test container for smoke-testing a built WLM image

## Package Source Files
| File | Used by |
|------|---------|
| `trilio.repo` | CentOS/RHEL-based images (YUM/DNF) |
| `delorean-component-tripleo.repo` | TripleO CentOS images |
| `trilio.list` | Ubuntu/Debian-based images (APT) |

## Build and Publish Scripts

Each platform directory contains:
- `build_containers.sh` — build all images for that platform
- `publish_containers.sh` — push built images to the registry

Individual component directories may also have their own `build_container.sh` and `publish_container.sh`.

## Key Conventions
- Never edit `*-DEP` Dockerfiles — they are kept only for historical reference.
- Startup script naming pattern: `start_<service>_<backend>` (e.g., `start_datamover_nfs`).
- The `trilio-common` base image (openstack-helm) must be built before other images in that platform.
- `nova-sudoers` in the datamover image is required — without it the datamover cannot interact with libvirt/QEMU on the compute node.
- Config files packaged into images (e.g., `datamover_logging.conf`, `dmapi.conf.sample`) serve as defaults that may be overridden at runtime via volume mounts or environment variables.
