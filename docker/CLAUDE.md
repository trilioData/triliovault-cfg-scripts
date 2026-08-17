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

## Image Size Hygiene (TVAULT-7629)

The Kolla datamover and WLM images had grown to 8.16 GB and 5.95 GB as actually measured
(TVAULT-7629 quotes 5.69/3.98 GB, taken earlier). Established rules —
apply these when touching any Dockerfile, and when converging the remaining releases
(2023.x / 2025.x) and the ubuntu variants onto the same pattern:

- **No blanket `dnf update -y` / `apt-get upgrade`.** It rewrites base-image files into a new
  layer while the originals stay resident in the base layer, so every updated file is stored
  twice. Pick up errata by bumping the `FROM` tag instead — both build scripts pass `--pull`.
- **Clean inside the layer that dirtied it.** `dnf clean all && rm -rf /var/cache/dnf` must be
  the tail of the *same* `RUN` as the installs. A clean in a later `RUN` cannot free bytes an
  earlier layer already committed. Same for `pip install --no-cache-dir` and `/root/.cache`.
- **`--setopt=install_weak_deps=False`** on dnf installs to keep RHEL9 `Recommends:` out —
  *except* where the Recommends are load-bearing. The `virt-v2v`/`virtio-win`/`nbdkit`
  transaction in trilio-datamover keeps default resolution because nbdkit ships plugins as
  Recommends and virt-v2v fails with "cannot open plugin" without them.
- **Build toolchain must be installed, used, and removed in one `RUN`.** Splitting the removal
  into its own layer reclaims nothing. Remove **only** `gcc gcc-c++ make python3-devel` —
  `libxslt-devel`, `openssl-devel` and `swig` are hard `Requires:` of `python3-workloadmgr-el9`
  and removing them guts the image (see the traps below).
- **Assert the runtime set after any `dnf remove`.** `dnf remove` also removes packages that
  *require* the named ones, so a cascade yields a broken image that still builds green. Both
  2024.1 rocky Dockerfiles end their install layer with `rpm -q <runtime packages>` plus
  import/`--version` checks; `set -e` turns a miss into a build failure.
- **One recursive `chown`/`chmod` pass, not several.** Each `-R` pass in its own layer
  duplicates every file of the tree it touches.
- **Verify with a before/after package manifest.** Build the pre-change image too, then diff
  `rpm -qa` between them (by NAME — see the traps below) to prove nothing was silently
  dropped. `docker images` for the size, `docker history` for per-layer attribution, and
  `du -x -m -d3 /` inside the container for where the bytes actually live.

Non-obvious traps found while doing this (all verified against real builds):

- **`dnf remove` of the toolchain cascades.** `python3-workloadmgr-el9` declares hard
  `Requires:` on `libxslt-devel`, `openssl-devel`, `swig` and `libxml2-devel`. Removing those
  makes dnf erase workloadmgr itself and 216 packages with it -- `python3-nova`,
  `openstack-nova-common`, `os-brick`, `oslo-db`, `taskflow`. **Only `gcc`, `gcc-c++`, `make`
  and `python3-devel` are safe to remove** (11 packages, ~171 MB). Always confirm a removal set
  with `dnf remove --assumeno` in the previous image before trusting it.
- **`udev` and `libguestfs-tools` are virtual `Provides:` on Rocky 9**, satisfied by
  `systemd-udev` and `virt-win-reg`. `dnf install udev` works but `rpm -q udev` always reports
  it missing. Assert on the *real* package name, or the build fails on a package that is fine.
  Validate any new assertion list against a known-good image before relying on it.
- **`docker image inspect .Size` lies under the containerd image store** (Docker 23+, default
  in 29.x): it returns the compressed content size -- 1.64 GB for a 5.95 GB image. Use
  `docker images` for the real unpacked figure.
- **Compare package manifests by NAME, not name-version-release.** With `dnf update` gone the
  new image keeps the base's versions, so a raw `rpm -qa` diff shows ~147 spurious
  version-drift entries that bury the real signal.
- In `trilio-wlm`, the pip `SQLAlchemy==1.4.51` pin **must** be installed before the
  workloadmgr RPMs, or an RPM-provided `python3-sqlalchemy` clobbers it. Preserve the order.
- `trilio-wlm` leaves epel *enabled* after the `python3-mysqlclient` install; the Trilio RPMs
  resolve with it on. Re-disabling it is a silent behaviour change.
- The `python3-novaclient` install→remove→install triple is only a no-op in the 2024.1+ files.
  `Dockerfile_zed_rocky` still carries the meaningful `--repo=centos-openstack-zed` third
  install (commit 24f40559) -- do not collapse that one.
- `namedatomiclock` (pip) imports as `NamedAtomicLock`, not lowercase.
- `OPENSTACK_RELEASE` in `kolla-ansible/devops-build-publish.sh` selects which
  `Dockerfile_<release>_<platform>` is built; defaults to 2025.1, env-overridable.
- Two build inputs are **not** in the repo and must be staged before building: the
  `virt-v2v-in-place` binary in `trilio-datamover/` (extractable from a published image at
  `/usr/local/bin/`; not shipped by any RPM -- Rocky's `virt-v2v` has no such binary), and a
  real `baseurl` in each `trilio.repo` (`https://yum.fury.io/trilio-6-2/`; the apt form
  `https://apt.fury.io/...` is for `trilio.list` and is not a valid yum `baseurl`).

### Security trade-off of removing `dnf update`

Removing it pins the image to the kolla base's package set. For the 2024.1 base that is
Rocky 9.7-level: openssh 8.7p1 not 9.9p1, openssl 3.5.1 not 3.5.5, sudo 1.9.5p2 not
1.9.17p2 -- ~147 packages. The kolla base does apply
`dnf -y distro-sync --security --sec-severity=Important` at its own build time, so
Important+ errata are covered as of then, and builds become reproducible instead of
drifting the OS minor version. **Bumping the `FROM` tag is now the only channel for newer
errata** -- revisit it when rebasing. Accepted deliberately under TVAULT-7629.

### Measured results (2024.1 rocky)

| Image | Published | Baseline rebuild | Optimized |
|-------|-----------|------------------|-----------|
| trilio-wlm | 5.95 GB | 5.12 GB | **3.85 GB** |

Most of the waste was layer duplication, not packages: the published datamover held 3.94 GB
of actual files in an 8.16 GB image, and the WLM 2.42 GB in 5.95 GB.

## Key Conventions
- Never edit `*-DEP` Dockerfiles — they are kept only for historical reference.
- Startup script naming pattern: `start_<service>_<backend>` (e.g., `start_datamover_nfs`).
- The `trilio-common` base image (openstack-helm) must be built before other images in that platform.
- `nova-sudoers` in the datamover image is required — without it the datamover cannot interact with libvirt/QEMU on the compute node.
- Config files packaged into images (e.g., `datamover_logging.conf`, `dmapi.conf.sample`) serve as defaults that may be overridden at runtime via volume mounts or environment variables.
