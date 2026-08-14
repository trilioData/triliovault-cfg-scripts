---
name: t4o-test
description: Run an end-to-end functional test of an already-deployed T4O installation on any OpenStack distro — licence, cloud admin trust, S3 and/or NFS backup targets with a reachability gate, trustee roles, test VMs with Cinder volumes of every available type, workloads and backups against the chosen target(s), and a PASS/FAIL report with root-cause analysis on failure. Use when asked to test, validate, or smoke-test a T4O install or a new build. Does not build and does not deploy.
---

# t4o-test

Drive the functional test suite in `test/` against a live T4O deployment, then
report and triage.

The suite is plain bash and runs standalone; this skill picks the target, sets
the scope, drives the steps, and does the root-cause work when something fails.

## Scope boundary — read this first

**This skill never builds and never deploys.** Artifacts are built and deployed
beforehand by other scripts, and deployment health checking belongs to
`/verify-deployment`. This skill assumes a working install and exercises it
functionally.

Never run `devops-build-publish.sh`, `charmcraft`, `docker build`,
`helm install/upgrade`, `juju deploy`, `ansible-playbook`, or `oc apply`. If T4O
is not deployed on the chosen setup, say so and stop — do not deploy it.

`env/build_artifacts.yaml` is read for exactly one purpose: naming the build in
the report header. Never compare deployed artifacts against it, and never pull
an image.

## Step 0 — Ask which setup, and which backup targets. Always.

**This is the first action, every run.** Never infer the setup from context,
from an argument, or from what was used last time. These are live lab and QA
clouds; the test creates VMs and volumes, applies a licence, adds backup
targets, and grants Keystone roles. Choosing the target is the user's call.

Ask both questions in a single `AskUserQuestion` call:

1. **Which setup** — read `C:\vscode-workspace\env\setups.yaml` (top-level key
   `setups:`) and offer every entry. Label is `name`; description is `platform`
   plus `used_for` when present. **Never render `ssh`, `host`, `user`, or any
   credential into the prompt.** The tool caps a question at 4 options and adds
   "Other" — with more entries, show the 4 most recently used and let the user
   type any other name.

2. **Which backup target(s)** — `Both` (recommended), `S3 only`, or `NFS only`.
   This sets `T4O_BT_SCOPE` to `both`, `s3`, or `nfs`. Everything downstream
   scales to it: one target, one VM, one workload for a single selection.
   Recommend `both` — it is the only mode that produces the cross-path
   diagnostic described under Triage.

If `setups.yaml` is missing or its `setups:` list is empty, stop and say so. Do
not fall back to asking for a host by hand.

## Step 1 — Prepare the setup

SSH to the selected entry, then:

```bash
mkdir -p ~/t4o-test
# copy the repo's test/ directory and the local env/ directory across
```

Two things that will bite otherwise:

- **Strip CRLF after copying.** This repo has `core.autocrlf=true`, so files in
  a Windows working tree have CRLF. A CR in a shebang fails as
  `/usr/bin/env: 'bash\r': No such file or directory`. Run
  `sed -i 's/\r$//' *.sh` on the copied scripts, then `chmod +x`.
- **Set `TRILIO_ENV_DIR`** to the env directory on that host (e.g.
  `/home/ubuntu/env`). The default resolves two levels up from `test/`, which is
  right for a normal checkout but wrong for a flat copy.

## Step 2 — Run the suite

```bash
cd ~/t4o-test/test
TRILIO_ENV_DIR=<env-dir> T4O_BT_SCOPE=<scope> bash run_all.sh
```

The backup step can take tens of minutes. Run it in the background and check
back rather than blocking.

### The reachability gate needs you

`01_check_backup_targets.sh` exits **2** when a selected backup target is not
reachable from the WLM service or from any DataMover node. That is a stop, not
a crash: **nothing has been created**, so recovery is free.

When it exits 2, show the user the per-node matrix and ask what to do:

| Option | Action |
|---|---|
| I've fixed it — re-check | re-run the gate unchanged |
| Use a different backup target | re-run with `T4O_S3_TARGET=<name>` or `T4O_NFS_TARGET=<name>`; the gate prints the available names |
| Change scope | re-run with a narrower `T4O_BT_SCOPE` to drop the failing type |
| Abort | stop; nothing was changed |

**Loop here — do not give up and do not press on.** Stay in this step,
re-checking on demand, until every selected target passes or the user aborts.
The whole point is that the user fixes the network or swaps the target while you
wait.

Read the matrix before reporting: a target failing from *every* node is a target
or firewall problem; failing from *one* node is that node's DNS, routing, or CA
trust. DNS, reachability and TLS are deliberately kept as separate rows because
they have different fixes.

## Step 3 — Report

`08_cleanup.sh` writes `t4o-test-report-<setup>-<date>.md` into the work dir.
Relay its contents. Keep two things intact:

- The scope, stated prominently. An untested target must read
  `NOT TESTED (scope: s3)` — never blank, never a pass. A single-target run must
  not be presentable as full coverage.
- The step-1 reachability matrix, including any re-checks and what changed
  between them.

Cleanup is conditional and already handled by the script: everything passed →
this run's resources are deleted; anything failed → nothing is deleted so the
state can be inspected. Backup targets are never deleted.

## Triage on failure

Do not just relay the error string. Work out the cause.

1. `wlm_logs` for the WLM side; `dm_logs <host>` for the DataMover on the node
   hosting the VM (`OS-EXT-SRV-ATTR:host`).
2. **In `both` mode, compare the two paths.** If S3 passed and NFS failed, or
   the reverse, the fault is in that target or its transport — not in WLM, the
   trust, or the VM. That halves the search space immediately.
   **In single-target mode this signal does not exist.** Say so explicitly and
   suggest re-running in `both` mode or against the other target. Never present
   a single-target failure as though the other path had been ruled out.
3. Match against `references/failure-modes.md` and state a concrete root cause.

## References

- `references/distro-adapters.md` — how each distro is reached, where its
  credentials live, and how licence and trust are applied.
- `references/cli-reference.md` — `workloadmgr` syntax, and the column-naming
  inconsistencies that fail commands outright.
- `references/failure-modes.md` — symptom → root cause.

## Related

- `test/README.md` — running the suite standalone, and adding a distro.
- [DevOps Reference Document](https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5125144595/DevOps+Reference+Document+for+Trilio+for+OpenStack) §15 — the single source of truth for this suite
- [Cloud Admin Credentials per Distro](https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5140414466)
