# verify-deployment

Build T4O artifacts, find the correct install documentation and any Confluence guides,
deploy T4O on the target environment, then verify the deployment.

## Usage

`/verify-deployment <env-name>`

- `env-name` — **Required.** Key from `environments.yaml` (e.g. `kolla-rocky-epoxy`).
- If `$ARGUMENTS` is empty, stop and tell the user: "Please provide an environment name. Available environments: (list keys from environments.yaml)"

---

## Step 1 — Load environment and determine context

Read `environments.yaml` from the repo root and load the entry matching `$ARGUMENTS`.
Collect: `deploy_host`, `build_host`.

Infer `distro` and `openstack_release` from the env-name and Jira context:
- Jira `fields.customfield_11300` (environment setup field) contains the distro, OS, and OpenStack release
- The env-name itself is descriptive (e.g. `kolla-rocky-epoxy` → kolla-ansible / rocky9 / 2025.1)

Determine **T4O release** and **build tag** from conversation context in this order:
1. Jira `fields.customfield_10200.name` → e.g. `"T4O-6.2.1"` → release = `6.2`, build tag = Jira topic branch (e.g. `tv7336`)
2. Current local git branch name (e.g. `tv7336`) → use as build tag; infer release from branch series
3. If still unknown — SSH into `deploy_host` and inspect a running container/pod image tag

---

## Step 2 — Build and publish artifacts on build_host

### 2a — Determine which components need a new build

Run a git diff on the topic branch to see which source paths changed:
```bash
git diff main..{topic_branch} --name-only
```

Map changed paths to T4O components using these rules:

| Changed path prefix | Component(s) affected |
|---------------------|-----------------------|
| `docker/kolla-ansible/trilio-wlm/` | wlm |
| `docker/kolla-ansible/trilio-datamover-api/` | datamover-api |
| `docker/kolla-ansible/trilio-datamover/` | datamover |
| `docker/kolla-ansible/trilio-horizon-plugin/` | horizon-plugin |
| `docker/openstack-helm/trilio-wlm/` | wlm |
| `docker/openstack-helm/trilio-datamover-api/` | datamover-api |
| `docker/openstack-helm/trilio-datamover/` | datamover |
| `docker/openstack-helm/trilio-horizon-plugin/` | horizon-plugin |
| `docker/redhat-director-scripts/docker/trilio-wlm/` | wlm |
| `docker/redhat-director-scripts/docker/trilio-datamover-api/` | datamover-api |
| `docker/redhat-director-scripts/docker/trilio-datamover/` | datamover |
| `docker/redhat-director-scripts/docker/trilio-horizon-plugin/` | horizon-plugin |
| `redhat-director-scripts/rhosp18/ctlplane-scripts/` | tvo-operator (control plane) |
| `redhat-director-scripts/rhosp18/dataplane-scripts/` | rhoso-ansible-runner (data plane) |
| `juju-charms/charm-trilio-wlm/` | wlm charm |
| `juju-charms/charm-trilio-dm-api/` | dm-api charm |
| `juju-charms/charm-trilio-data-mover/` | data-mover charm |
| `juju-charms/charm-trilio-horizon-plugin/` | horizon-plugin charm |
| `kolla-ansible/` | all kolla components (roles affect all) |

If a changed path does not map to a specific component, build **all** components for that distro.

### 2b — Fetch last build details and repo URLs from Confluence

Fetch the **Latest Build Details** Confluence page:
- Page ID: `5025333249`
- URL: https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5025333249/Latest+Build+Details

Use `mcp__atlassian__getConfluencePage` (cloudId `a88c0fc6-1d84-446d-909e-8936125c2623`, pageId `5025333249`).

Find the section matching `{t4o_release}` (e.g. `T4O 6.2.0`) and extract:

**Repo URLs** — from the `REPO URLS` table in that release section:
- `RPM_REPO_URL` — RPM row value (used for rocky/RHEL-based container builds)
- `DEB_REPO_URL` — DEBIAN row value (used for ubuntu/Debian-based container builds)
- `PIP_REPO_URL` — PIP row value (used as `TRILIO_PIP_INDEX_URL` build arg for horizon-plugin)

These are **required** for any container/image build. If any value is missing from the page, stop and tell the user: "Cannot build — {field} is missing from the Latest Build Details Confluence page for {t4o_release}. Please update the page."

**Last build details** — from the `Containers and Charms` table, row matching `{distro}`:
- **kolla / rhoso18 / mosk**: image tag for each component (e.g. `tv7300`)
- **canonical**: charm revision number for each charm (e.g. `Datamover Charm: 72`)

For every component that has **no changed files** in the git diff, use the tag/revision from this table instead of building a new one. Record these as `{component}_tag = <last_tag>`.

If the Confluence page has no `Containers and Charms` entry for this distro/release yet, build all components.

### 2c — Build only changed components

**Script locations** (relative to repo root):

| Distro | `devops-build-publish.sh` path |
|--------|-------------------------------|
| kolla-ansible | `docker/kolla-ansible/devops-build-publish.sh` |
| openstack-helm / mosk | `docker/openstack-helm/devops-build-publish.sh` |
| rhosp17 | `docker/redhat-director-scripts/docker/devops-build-publish.sh` |
| rhosp18 | `redhat-director-scripts/rhosp18/build/devops-build-publish.sh` |
| canonical | `juju-charms/devops-build-publish.sh` |

SSH into `build_host`: `ssh -o StrictHostKeyChecking=no {build_host} "{command}"`

Determine the **repo URL**: `git remote get-url origin`

Create a clean workspace, clone and checkout the topic branch:
```bash
ssh {build_host} "rm -rf /tmp/build-claude && mkdir -p /tmp/build-claude"
ssh {build_host} "cd /tmp/build-claude && git clone {repo_url} triliovault-cfg-scripts"
ssh {build_host} "cd /tmp/build-claude/triliovault-cfg-scripts && git checkout {topic_branch}"
```

Set `{repo_path}` = `/tmp/build-claude/triliovault-cfg-scripts`.

Export the repo URLs as env vars on `build_host`, then run `devops-build-publish.sh` passing **only the changed component(s)**:

#### kolla-ansible
```bash
# Build only the changed container (e.g. datamover)
ssh {build_host} "cd {repo_path}/docker/kolla-ansible && \
  RPM_REPO_URL='{rpm_repo_url}' \
  DEB_REPO_URL='{deb_repo_url}' \
  PIP_REPO_URL='{pip_repo_url}' \
  bash devops-build-publish.sh {build_tag} {os_platform} {component}"
# e.g. ... bash devops-build-publish.sh tv7336 rocky trilio-datamover
```
Unchanged containers keep their tag from Step 2b.
(`RPM_REPO_URL` is used for rocky; `DEB_REPO_URL` for ubuntu; `PIP_REPO_URL` for horizon-plugin on both platforms.)

#### rhosp17
```bash
ssh {build_host} "cd {repo_path}/docker/redhat-director-scripts/docker && \
  RPM_REPO_URL='{rpm_repo_url}' \
  bash devops-build-publish.sh {build_tag} rhosp17.1 {component}"
# e.g. ... bash devops-build-publish.sh tv7336 rhosp17.1 trilio-datamover
```
Unchanged containers keep their tag from Step 2b.

#### rhoso18
The ansible-runner image installs no packages — no repo URL needed.
Build only the affected image based on which path changed:
```bash
# ctlplane changed → rebuilds tvo-operator only
# dataplane changed → rebuilds rhoso-ansible-runner only
# both changed → rebuilds both
ssh {build_host} "cd {repo_path}/redhat-director-scripts/rhosp18/build && \
  bash devops-build-publish.sh {build_tag}"
```
Unchanged image keeps its last tag from Step 2b.

#### canonical
Juju charms install no packages at build time — no repo URL needed.
```bash
# Build only the changed charm (e.g. data-mover)
ssh {build_host} "cd {repo_path}/juju-charms && \
  bash devops-build-publish.sh {charm_short_name}"
# e.g. bash devops-build-publish.sh data-mover
```
Unchanged charms keep their last revision from Step 2b.

#### mosk / openstack-helm
```bash
ssh {build_host} "cd {repo_path}/docker/openstack-helm && \
  DEB_REPO_URL='{deb_repo_url}' \
  PIP_REPO_URL='{pip_repo_url}' \
  bash devops-build-publish.sh {build_tag} {openstack_release} {component}"
# e.g. ... bash devops-build-publish.sh tv7336 mosk22.4_yoga trilio-datamover
```
Unchanged containers keep their tag from Step 2b.

### 2d — Update the Latest Build Details Confluence page

After all builds complete, update the Confluence page with the new build details so future runs can use them.

Use `mcp__atlassian__updateConfluencePage` (pageId `5025333249`) to update the row for `{t4o_release}` / `{distro}`:
- For rebuilt components: write the new `{build_tag}`
- For unchanged components: leave their existing tag/revision in place
- Format matches the existing page (table row per distro, e.g. `Image tag: tv7336 | wlm: tv7300 | datamover: tv7336 | datamover-api: tv7300`)

---

## Step 3 — Find install documentation and Confluence guides

### 3a — Construct and fetch the install doc URL

**Base URL** (from T4O release):

| T4O release | Base |
|-------------|------|
| `6.1` | `https://docs.trilio.io/openstack/deployment` |
| `6.2` or any `6.x` ≥ 6.2 | `https://docs.trilio.io/openstack/t4o-6.x/deployment` |
| any `5.x` | `https://docs.trilio.io/openstack/t4o-5.x/deployment` |
| any `4.x` | `https://docs.trilio.io/openstack/tvo-4.x/deployment` |

**Distro path** (from inferred `distro`):

| distro | Path |
|--------|------|
| `rhoso18` | `installing-on-rhosp/trilio_installation_on_rhoso` |
| `rhosp17` | `installing-on-rhosp/rhosp17` |
| `kolla-ansible` | `installing-on-kolla` |
| `canonical` | `installing-on-canonical` |
| `mosk` | `installing-on-mosk` |
| `openstack-helm` | `installing-on-openstack-helm` |

Fetch the doc using WebFetch:
> "Extract the complete deployment steps, configuration commands, image tag placeholders, and the full verification section at the end of the document (including every command and its expected output)."

### 3b — Search Confluence for Jira-related deployment guides

If a Jira key is in context (e.g. `TVAULT-7336`), search Confluence for pages created as part of that Jira:

Use `mcp__atlassian__searchConfluenceUsingCql` with:
```
CQL: text ~ "{jira_key}" AND space.key = "TD" ORDER BY lastmodified DESC
```

Also check remote links on the Jira issue using `mcp__atlassian__getJiraIssueRemoteIssueLinks` — these often include directly linked Confluence pages.

If any Confluence pages are found, fetch them with `mcp__atlassian__getConfluencePage` and extract any deployment-specific instructions, config values, or environment-specific overrides they contain.

Use the Confluence content to supplement the install doc — Confluence pages may contain environment-specific values (image registry URLs, keystone endpoints, node IPs) not in the public doc.

---

## Step 4 — Deploy T4O on deploy_host

SSH into `deploy_host`. Use the Bash tool: `ssh -o StrictHostKeyChecking=no {deploy_host} "{command}"`

Follow the install doc steps from Step 3a, augmented by any Confluence content from Step 3b.
Replace image tag placeholders in the doc with `{build_tag}` from Step 2.

### kolla-ansible

Update the image tag in the globals file and run the site playbook:
```bash
# Update image tags in globals
ssh {deploy_host} "sed -i 's/triliovault_tag:.*/triliovault_tag: \"{build_tag}\"/g' \
  {kolla_config_path}/triliovault_globals_{openstack_release}.yml"

# Deploy
ssh {deploy_host} "cd {kolla_config_path} && \
  ansible-playbook -i triliovault_inventory.txt \
  triliovault_site_{openstack_release}.yml --tags deploy"
```

### rhoso18

Update operator inputs with new image tags and run control + data plane deployment:
```bash
# Update image tag in operator inputs
ssh {deploy_host} "cd {ctlplane_path} && \
  ./set_operator_inputs.py {build_tag} && \
  ./deploy_tvo_control_plane.sh"

# Data plane
ssh {deploy_host} "cd {dataplane_path} && \
  oc -n openstack apply -f trilio-data-plane-deployment.yaml"
```

### canonical

First remove all existing Trilio charms (including mysql-router subordinates), then redeploy from Charmhub:

```bash
# Remove all Trilio applications
ssh {deploy_host} "juju remove-application trilio-wlm trilio-dm-api trilio-data-mover trilio-horizon-plugin trilio-dm-api-mysql-router trilio-wlm-mysql-router trilio-data-mover-mysql-router --force"
```

Poll every 30 seconds (up to 15 minutes) with:
```bash
ssh {deploy_host} "juju status --format=short 2>&1 | grep -i trilio || echo NONE"
```

**Do not proceed until the output is `NONE`** — meaning every trilio application and unit has been fully removed from the model. If any trilio application is still present after 15 minutes, stop and report: "Charm removal timed out — the following applications are still present: (list them). Manual intervention required before redeployment."

Only once removal is confirmed, deploy fresh from the install doc steps, using the charm revisions from Step 2b for unchanged charms and the newly published revision for the rebuilt charm.

After deploy, wait for all units to settle:
```bash
ssh {deploy_host} "juju wait-for application trilio-wlm --timeout 15m"
```

### mosk / openstack-helm

```bash
ssh {deploy_host} "helm upgrade triliovault {chart_path} \
  --set global.imageTag={build_tag} \
  --namespace triliovault"
```

After running deployment commands, wait for the environment to stabilise before proceeding to verification (poll every 30s for up to 10 minutes).

---

## Step 5 — Verify deployment

Use three sources to build the complete verification checklist, then run all checks.

### 5a — Install doc verification section

Every docs.trilio.io install guide ends with a "Verify deployment" (or "Verify Installation") section. Locate it in the Step 3a doc content and extract every command and its expected output.

### 5b — Jira issue changes

Re-read the Jira issue (using `mcp__atlassian__getJiraIssue`) and scan:
- Issue description and all comments for mentions of new pods, containers, services, CRDs, Helm resources, Juju units, or config changes introduced by this fix
- Any acceptance criteria or "how to verify" notes written by the developer

For every new or changed component mentioned, construct an appropriate verification command:
- New pod → `kubectl/oc get pods -A | grep <name>` or `docker ps | grep <name>`
- New service → check it appears in the process list or service status
- New CRD / CR → `oc get <kind> -A`
- New Juju unit → `juju status | grep <charm>`
- Config change → read the relevant config file and confirm the value

### 5c — Confluence pages from Step 3b

For each Confluence page fetched in Step 3b, extract any verification steps, testing notes, or "expected state after deployment" sections and add those checks to the list.

### Run all checks

Execute every check from 5a + 5b + 5c via SSH: `ssh -o StrictHostKeyChecking=no {deploy_host} "{command}"`

Compare actual output against the expected state from its source (install doc, Jira, or Confluence).

If the fetched install doc did not contain a verification section (fetch failed or section missing), fall back to these defaults:

### rhoso18 (fallback)
```bash
ssh {deploy_host} "oc -n trilio-openstack get pods -o wide"
ssh {deploy_host} "oc -n trilio-openstack get tvocontrolplane"
ssh {deploy_host} "oc -n openstack get OpenStackDataPlaneDeployment"
```
Expected: All pods `Running` or `Completed`. `tvocontrolplane` CR `Ready`.

### kolla-ansible (fallback)
```bash
ssh {deploy_host} "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -i trilio"
```
Expected: `triliovault_wlm_api`, `triliovault_wlm_workloads`, `triliovault_wlm_scheduler`, `triliovault_wlm_cron`, `triliovault_datamover_api` `Up` on controller; `triliovault_datamover` `Up` on each compute node.

### canonical (fallback)
```bash
ssh {deploy_host} "juju status --format=short | grep -i trilio"
```
Expected: All `trilio-*` units `active (idle)` with message `Unit is ready`.

### mosk / openstack-helm (fallback)
```bash
ssh {deploy_host} "kubectl get pods -A | grep trilio"
```
Expected: All trilio pods `Running` or `Completed`.

---

## Step 6 — Verify the Jira fix (DevOps side)

This step verifies that the specific changes introduced by the Jira fix are actually present and correct on the deployed environment. It is separate from the general deployment health check in Step 5.

### 6a — Understand what changed in this fix

Read the Jira issue (`mcp__atlassian__getJiraIssue`) and collect:
- Issue summary and description — what problem was being fixed
- Developer comments — any "how to test" or "what changed" notes
- Linked Confluence pages from Step 3b — look for sections like "Changes made", "New components", "Modified configs"

Then inspect the local git diff for the topic branch:
```bash
git log main..{topic_branch} --oneline
git diff main..{topic_branch} -- .
```

For each changed file, determine what DevOps-observable effect it should have on the deployed environment.

### 6b — Map changes to verification checks

For each type of change found, run the corresponding check on `deploy_host`:

**Script or playbook changed** (e.g. `triliovault_site_2025.1.yml`, `set_operator_inputs.py`)
- Confirm the script was invoked during deployment (check deploy output from Step 4)
- If the script writes output files or modifies configs, verify the output reflects the change

**New or renamed container / pod**
- `docker ps | grep <name>` / `oc get pods -A | grep <name>` / `kubectl get pods -A | grep <name>`
- Confirm it is `Up` / `Running` and using image tag `{build_tag}`

**Removed container / pod** (intentionally deleted as part of fix)
- Confirm it is no longer present

**Config file changed** (e.g. globals YAML, Helm values, charm config option)
- Read the relevant config on `deploy_host` and confirm the new value is present
- kolla: `ssh {deploy_host} "grep <key> {kolla_config_path}/triliovault_globals_{openstack_release}.yml"`
- rhoso18: `ssh {deploy_host} "oc -n trilio-openstack get cm -o yaml | grep <key>"`
- canonical: `ssh {deploy_host} "juju config trilio-wlm | grep <key>"`
- mosk: `ssh {deploy_host} "helm get values triliovault -n triliovault | grep <key>"`

**New Juju relation or action**
- `ssh {deploy_host} "juju status --relations"` — confirm relation is listed
- `ssh {deploy_host} "juju actions <charm>"` — confirm new action appears

**New CRD or CR (rhoso18)**
- `ssh {deploy_host} "oc get crd | grep trilio"`
- `ssh {deploy_host} "oc get <kind> -A"`

**Image tag updated**
- Confirm running containers use `{build_tag}`, not a stale tag:
  - kolla: `ssh {deploy_host} "docker inspect triliovault_wlm_api | grep Image"`
  - rhoso18: `ssh {deploy_host} "oc -n trilio-openstack get pods -o jsonpath='{.items[*].spec.containers[*].image}'"`
  - canonical: `ssh {deploy_host} "juju status --format=json | python3 -c \"import json,sys; d=json.load(sys.stdin); [print(u) for a in d['applications'].values() for u in a.get('charm-url',[])]\""`
  - mosk: `ssh {deploy_host} "kubectl get pods -n triliovault -o jsonpath='{.items[*].spec.containers[*].image}'"`

**Log output / service behaviour change**
- If the fix changes what a service logs or how it responds, check recent logs:
  - kolla: `ssh {deploy_host} "docker logs --tail 50 triliovault_wlm_api"`
  - rhoso18: `ssh {deploy_host} "oc logs -n trilio-openstack deployment/wlm-api --tail=50"`
  - canonical: `ssh {deploy_host} "juju debug-log --include trilio-wlm --lines 50"`

### 6c — Run all fix-specific checks

Execute each check from 6b. For each one record: what was changed, what was verified, and whether it matches the expected state.

---

## Step 7 — Report

For every check across Steps 5 and 6:
- **PASS** — present and in expected state
- **FAIL** — missing or in error/crash state
- **WARN** — present but not in expected state

Source tags:
- `[doc]` = install doc verification section
- `[jira]` = new/changed component inferred from Jira description/comments
- `[confluence]` = check from Confluence page
- `[fix]` = specific change introduced by this Jira fix (from git diff + Jira)

If any FAIL or WARN, quote the relevant section from the install doc, Confluence page, or git diff to help diagnose the issue.

### 7a — Write report file

Write the full report to a Markdown file in the **repo root directory**:

**Filename**: `deployment-report-{env-name}-{topic_branch}-{YYYY-MM-DD}.md`
(e.g. `deployment-report-kolla-rocky-epoxy-tv7336-2025-05-22.md`)

Use the Write tool to create the file. Content format:

```markdown
# Deployment Report

| Field        | Value |
|--------------|-------|
| Environment  | {env-name} ({distro} / {openstack_release}) |
| T4O Release  | {t4o_release} |
| Build Tag    | {build_tag} |
| Jira         | {jira_key} — {jira_summary} |
| Date         | {YYYY-MM-DD HH:MM UTC} |
| Install Doc  | {install_doc_url} |
| Confluence   | {confluence_url} (or "none") |
| Overall      | PASS / DEGRADED / FAIL |

---

## Artifacts

| Image / Artifact | Tag | Status |
|------------------|-----|--------|
| docker.io/trilio/kolla-rocky-trilio-wlm | tv7300 | REUSED (unchanged) |
| docker.io/trilio/kolla-rocky-trilio-datamover | tv7336 | BUILT |
| ... | | |

---

## Deployment

| Step | Command | Result |
|------|---------|--------|
| Update image tag | sed triliovault_globals_2025.1.yml | DONE |
| Run playbook | ansible-playbook triliovault_site_2025.1.yml | DONE |

---

## Deployment Health

| Result | Source | Component | Detail |
|--------|--------|-----------|--------|
| PASS | [doc] | triliovault_wlm_api | Up 5 minutes |
| PASS | [doc] | triliovault_datamover_api | Up 5 minutes |
| FAIL | [doc] | triliovault_datamover | not found — check compute nodes |

---

## Jira Fix Verification

| Result | Component / Check | Detail |
|--------|-------------------|--------|
| PASS | config key backup_target_timeout | present in triliovault_globals_2025.1.yml |
| PASS | image tag triliovault_wlm_api | tv7336 (expected) |
| FAIL | triliovault_site_2025.1.yml change | wlm_cron still using old value |

---

## Failures and Next Steps

(For each FAIL or WARN, paste the relevant troubleshooting extract from the install doc or Confluence page, and suggest a next action.)
```

### 7b — Print summary to console

After writing the file, print the same report to the conversation so the user can read it inline.
Output the file path at the top: `Report written to: deployment-report-{env-name}-{topic_branch}-{YYYY-MM-DD}.md`
