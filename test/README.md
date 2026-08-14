# T4O functional test suite

End-to-end functional test of an **already-deployed** T4O installation, on any
supported OpenStack distribution.

It answers one question that no other check in this repo answers: *does this
deployment actually back up a VM?* `.claude/commands/verify-deployment.md`
stops at "pods and containers are Running"; this suite carries on through the
licence, the cloud admin trust, backup targets, a real VM with volumes, a
workload, and a full snapshot.

The `t4o-test` skill drives this suite, but the suite does not need it — it is
plain bash and runs standalone from any host with access to the cloud.

## What it does NOT do

**It never builds and never deploys.** Artifacts are built and deployed
beforehand by other scripts. This suite assumes a working install and exercises
it. If T4O is not deployed, step 01 says so and stops rather than installing it.

It reads `env/build_artifacts.yaml` for exactly one purpose: naming the build in
the report header. It never pulls an image and never compares deployed artifacts
against expected ones.

## Requirements

Run from a host that can reach the cloud's control plane with the usual admin
tooling for that distro (`kubectl`/`oc`/`juju`/`docker`/`podman`), plus an
`env/` directory containing:

| File | Purpose |
|---|---|
| `backup_targets.yaml` | S3 and NFS target definitions (`triliovault_backup_targets:`) |
| `license_trilio.txt` | the T4O licence |
| `build_artifacts.yaml` | optional — names the build in the report |

`TRILIO_ENV_DIR` points at that directory. It defaults to two levels up from
this one (`<repo-parent>/env`), which is correct for a normal checkout; set it
explicitly for a flat clone.

## Usage

### Through the `t4o-test` skill (interactive)

```
/t4o-test
```

It asks two questions up front — **which setup** (from `env/setups.yaml`) and
**which backup targets** (S3, NFS, or both) — then copies the suite to that
setup, detects the distro, runs every step, and triages anything that fails.

It never assumes the setup. These are live lab and QA clouds and the test
creates VMs, applies a licence and grants Keystone roles, so the target is
always an explicit choice.

### Standalone (no Claude)

Copy this directory and your `env/` directory to a host that can reach the
cloud, then:

```bash
# everything, both backup targets
bash test/run_all.sh

# one target only — one target, one VM, one workload, one backup
T4O_BT_SCOPE=s3  bash test/run_all.sh
T4O_BT_SCOPE=nfs bash test/run_all.sh

# a specific entry from backup_targets.yaml
T4O_S3_TARGET=BT2_S3 bash test/run_all.sh

# individual steps, in order
bash test/01_check_backup_targets.sh
```

### Environment

| Variable | Meaning |
|---|---|
| `T4O_BT_SCOPE` | `s3` \| `nfs` \| `both` (default `both`) |
| `T4O_S3_TARGET` / `T4O_NFS_TARGET` | use a named entry instead of the default-flagged one |
| `T4O_DISTRO` | skip detection and force an adapter |
| `TRILIO_ENV_DIR` | directory holding `backup_targets.yaml` etc. |
| `T4O_WORK_DIR` | scratch dir for openrc, resources, report (default `~/t4o-test`) |

## The steps

| Step | What it does |
|---|---|
| `01_check_backup_targets.sh` | **Hard gate.** Reachability from WLM *and* every DataMover node. Creates nothing. |
| `02_apply_license.sh` | Applies the licence; verifies with `license-list`. |
| `03_create_cloud_trust.sh` | Creates the cloud admin trust; verifies with `trust-list`. |
| `04_create_backup_targets.sh` | Creates the selected target(s), or reuses an existing one. |
| `05_verify_trustee_roles.sh` | Reads live `trustee_role`; grants any the test user lacks. |
| `06_create_test_resources.sh` | One VM per selected target, plus a volume of every available type. |
| `07_workload_and_backup.sh` | One workload and one full backup per selected target. |
| `08_cleanup.sh` | Writes the report; cleans up only if every tested backup passed. |

### Why step 01 comes first

An unreachable backup target makes the whole run pointless, and every later step
would leave state behind on a cloud that was never going to produce a backup.
Probing first means a failed run changes nothing.

It probes from the WLM service **and** from every DataMover node, because those
sit on different hosts: WLM writes JSON metadata, the DataMover writes the qcow2
data. A target only WLM can reach yields a workload that creates fine and then
fails mid-snapshot — exactly the failure this gate exists to prevent.

On failure it exits **2** having changed nothing, prints a per-node matrix, and
tells you how to recover: fix the problem, pick another target, narrow the
scope, or stop.

### Cleanup rules

- Every tested backup passed → the snapshots, workloads, VMs and volumes **this
  run created** are deleted.
- Any tested backup failed → **nothing** is deleted, so you can inspect it.
  Re-run `08_cleanup.sh --force` when you are done.
- **Backup targets are never deleted.** They are shared infrastructure.
- Cleanup only touches IDs in this run's `resources.env`. Leftovers from an
  earlier run, or anyone else's resources, are never removed.
- The generated `openrc` is removed either way.

## Also documented in

- **DevOps Build and Testing Reference**, section 14 — the same how-to in the
  context of the full build/deploy/test cycle, including which of the 10 build
  pass criteria a green run actually covers.
- **DevOps Implementation Reference**, section 10 (Verification) — points here
  as the automated alternative to verifying by hand.

## Adding a distro

Everything distro-specific lives in `t4o_env.sh`. Add a branch to
`detect_distro()`, `_t4o_set_distro_constants()`, and each helper:
`wlm_exec`, `wlm_shell`, `os_exec`, `wlm_conf`, `wlm_logs`, `dm_hosts`,
`dm_shell`, `dm_logs`, `copy_to_wlm`, `discover_cloud_admin`. The numbered
scripts should not need to change — if one does, the abstraction is leaking.

`dm_hosts` prints an opaque **handle** per DataMover node; only `dm_shell` and
`dm_logs` need to know what it is (a Juju unit name on Sunbeam and Canonical, a
compute hostname elsewhere).

## Notes that cost time to rediscover

- **`workloadmgr` must run inside the WLM service.** The
  `python3-workloadmgrclient` plugin ships only in the WLM image, never on a
  bastion or build host.
- **`trust-create` exits 0 even on HTTP 500.** The only proof a trust exists is
  a non-empty `trust-list`.
- **`backup-target-list` has no Name column.** A backup *target* is identified
  by its `Backend Endpoint`; the name lives on the backup target *type*, which
  is what `workload-create --backup-target-type` consumes. They are frequently
  different, so never assume the name in `backup_targets.yaml` is the one to
  build a workload on.
- **`--instance` takes a bare UUID.** The `instance-id=<uuid>` form in the docs
  is the positional-argument syntax and fails against the flag.
- **`--accept-eula` is required** on `license-create`, or it blocks forever on a
  curses EULA prompt.
- **Never split an NFS export on `/`** to derive server or path — see
  TVAULT-7419.
- **Sunbeam needs `setsid`** in front of `workloadmgr`, and only Sunbeam. Pebble
  hands the process a controlling terminal and cliff/cmd2 then dies in
  `curses.cbreak()`.
