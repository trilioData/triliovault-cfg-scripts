# triliovault-cfg-scripts — CLAUDE.md
This repository holds Trilio deployment and upgrade scripts for following openstack distros
1. Kolla-ansible  : ./triliovault-cfg-scripts/kolla-ansible
2. Redhat OpenStack RHOSO18 : ./triliovault-cfg-scripts/redhat-director-scripts/rhoso18
3. Redhat OpenStack RHOSP17.1 : ./triliovault-cfg-scripts/redhat-director-scripts/rhosp17
4. Canonical OpenStack - Juju charms based: ./triliovault-cfg-scripts/juju-charms
5. Sunbeam Canonical OpenStack : ./triliovault-cfg-scripts/sunbeam-canonical
6. OpenStack Helm and MOSK: ./triliovault-cfg-scripts/openstack-helm


## Introduction
T4O is shortform for Trilio for OpenStack product
In triliovault-cfg-scripts repo we keep all deployment scripts to deploy and upgrade T4O on different OpenStack distributions clouds like RedHat OpenStack, Kolla Ansible OpenStack, Mirantis OpenStack, Canonical OpenStack etc.
You need to understand openstack architecture to work on this project
https://www.openstack.org/software/

## DevOps Reference Document — SINGLE SOURCE OF TRUTH

**https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5125144595/DevOps+Reference+Document+for+Trilio+for+OpenStack**

This Confluence page is the authoritative, distro-agnostic implementation reference for T4O: every service and its start command, node placement, Ubuntu + CentOS/RHEL 9 package lists and Python pins, users/UIDs, directories, kernel modules, FUSE, sudoers/rootwrap, DB/RabbitMQ/Keystone bootstrap, **every config-file parameter with an explanation and how to derive its value**, container mounts and flags (Kolla + RHOSO 18), HAProxy, start order, verification, upgrade, and known failure modes.

Use it for two things:
1. **Writing install/upgrade automation for a new OpenStack distro** — implement its sections in order; §13 is the completion checklist.
2. **Diagnosing bugs in existing devops scripts** — diff the deployed artefact against its reference tables. §7.10 (cross-file consistency rules) and §12 (symptom → root cause) resolve most field issues.

Keep it current: when a fix changes a service command, package, directory, config parameter, mount, or ordering constraint, update that page in the same change as the code.

### Companion: DevOps Build and Testing Reference

**https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5126914053/DevOps+Build+and+Testing+Reference**

The build/test execution counterpart: what artefacts to build for each distro and with which script, deploy, apply the licence, validate the cloud admin trust, add NFS and S3 backup targets, create a workload and take full + incremental backups, restore, and test an upgrade from build X to build Y. Contains the 10 pass criteria used to sign off a build and a per-run test record template.

Keep it current when a build script gains or changes arguments, when the artefact list for a distro changes, or when a new validation step becomes necessary.

### Known convention drift: WLM Keystone service user

The WLM Keystone service user is **`workloadmgr`**. Several distro defaults still ship the older name `triliovault` and should be aligned:
- `kolla-ansible/ansible/roles/triliovault/defaults/main.yml` → `triliovault_wlm_keystone_user`
- `kolla-ansible/ansible/input_values.txt` → `WLM_USER_NAME`
- `openstack-helm/trilio-openstack/` → `endpoints.identity.auth.triliovault_wlm.username`

**Do not rename the user on a live cloud.** `cloud_unique_id` in the WLM config is this user's Keystone *ID* and stamps every workload — creating a new user changes the ID and orphans existing workloads. Renaming is a planned-migration task, not a config fix.

## T4O Product Documentation Links

- **Trilio for OpenStack (T4O) Complete Document**: https://docs.trilio.io/openstack/
- **T4O Installation Guide on RHOSO18**: https://docs.trilio.io/openstack/deployment/installing-on-rhosp/trilio_installation_on_rhoso
- **T4O Installation Guide on RHOSP17**: https://docs.trilio.io/openstack/deployment/installing-on-rhosp/rhosp17
- **T4O Installation Guide on Canonical**: https://docs.trilio.io/openstack/deployment/installing-on-canonical


## T4O Product Architecture from DevOps Perspective
- We have following components from a devops perspective
1. Workloadmanager also known as 'workloadmgr'
This is component is splitted in four microservices. wlm-api, wlm-workloads, wlm-cron and wlm-scheduler. 
These all services are control plane servcies and should be installed on control plane nodes.
Wlm cron service should be installed with only one instance
2. Datamover Api - also called as 'dmapi' 
This is a control plane service and should be installed on control plane nodes of OpenStack cloud
3. Datamover - This components needs to be installed and co-located on all compute nodes(Where nova-compute service is installed) on OpenStack Cloud. 
4. Trilio Horizon Plugin 
This is a UI plugin for T4O and it should be installed on OpenStack's horizon container.


---

## Repository Structure

```
triliovault-cfg-scripts/
├── ansible/                        # Generic Ansible deployment (bare-metal/VM installs)
├── common/                         # Shared utilities (NFS map generator, nova user scripts)
├── conf-files/                     # Systemd service files and config templates
├── docker/                         # Dockerfiles for all TrilioVault component images
├── juju-charms/                    # Juju charm source code for Canonical OpenStack (wlm, dmapi, data-mover, horizon-plugin)
├── kolla-ansible/                  # Kolla Ansible roles (Zed, Antelope, Bobcat)
├── migration-vm2os/                # VM to OpenStack migration helpers
├── openstack-helm/                 # Helm charts (OpenStack Helm / MOSK)
├── redhat-director-scripts/        # Red Hat RHOSP 16/17 and RHOSO 18
└── tripleo/                        # TripleO (Train, Wallaby)
```

## Branching Strategy for devops repo triliovault-cfg-scripts
- For first release every series, we create one dev-stable/<RELEASE> branch for developemnt. For example for 6.1.0 release, we create dev-stable/6.1 branch. This branch gets used during active development period.
- We create one more branch for this release called 'stable/<RELEASE>'. We merged dev-stable/<RELEASE> branch into stable/<RELEASE> branch in the last phase of that release development.
- For next releases of T4O in that given series like 6.1.1, 6.1.2 etc, we create dev-maint<MINOR_RELEASE>/<MAJOR_RELEASE> branch.
  Like for 6.1.2 release, we create dev-maint2/6.1 branch for development purpose.
- We create one more branch covering all maintainance releases of that series, to hold stable code changes, called, maint/<MAJOR_RELEASE> like maint/6.1

---
### Details on how devops scripts are designed for each OpenStack distributions
- We have separate scripts designed to deploy T4O product on each openstack distribution.
1. RHOSO18 Install Scripts Details

-- RHOSO18 OpenStack Install Guide
https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0/html/deploying_red_hat_openstack_services_on_openshift/index

-- T4O Control plane services scripts are designed as a helm based operator
-- T4O Data plane services scripts are designed as ansible scripts

2. RHOSP17.1
-- We have designed these scripts by reffering RedHat OpenStack 17.1 services
-- RHOSP17.1 openstack install document : https://docs.redhat.com/en/documentation/red_hat_openstack_platform/17.1/html/installing_and_managing_red_hat_openstack_platform_with_director/index
-- We use technologies like Puppet, Heat and ansible here.


3. Canonical OpenStack
-- We have designed four juju charms. 1. wlm charm 2. dmapi charm 3. data-mover charm 4. horizon plugin charm
-- Charm source code lives in juju-charms/ directory (charm-trilio-wlm, charm-trilio-dm-api, charm-trilio-data-mover, charm-trilio-horizon-plugin)
-- We keep all charms published on Charmhub. Use charmcraft pack / charmcraft upload / charmcraft release from the charm subdirectory to build and publish.
-- Charms use the charms_openstack framework with the reactive pattern (charms.reactive)
-- Refer Juju and charms_openstack documentation for charm development
-- Canonical OpenStack Charm Development Guide: https://opendev.org/openstack/charm-guide



---
## Deployment Platforms

| Directory | Platform | Method | OpenStack Versions |
|-----------|----------|--------|--------------------|
| `ansible/` | Generic OpenStack | Ansible roles | Any |
| `kolla-ansible/` | Kolla OpenStack | Ansible + Kolla | Zed, Antelope, Bobcat |
| `openstack-helm/` | OpenStack Helm / MOSK | Helm charts | Antelope, Bobcat, Epoxy |
| `juju-charms/` | Canonical OpenStack | Juju charms (reactive, charms_openstack) | Yoga, Antelope, Bobcat, Caracal |
| `redhat-director-scripts/rhosp16/` | RHOSP 16 | Puppet + Heat | Queens |
| `redhat-director-scripts/rhosp17/` | RHOSP 17 | Puppet + Heat | Wallaby |
| `redhat-director-scripts/rhosp18/` | RHOSO 18 | Operator + Ansible | RHOSO 18.0 |
| `tripleo/` | TripleO | Puppet + Heat | Train, Wallaby |

---

## Local Workspace Environment (`C:\vscode-workspace\env\`)

A sibling directory `env/` at the workspace root holds local credentials and test-environment config that must NOT be committed to any repo. Test scripts reference it via `TRILIO_ENV_DIR` env var (default: three levels up from `sunbeam-canonical/test/`).

| File | Purpose |
|------|---------|
| `backup_targets.yaml` | Backup target definitions for automated tests. Contains S3 endpoints, bucket names, access/secret keys, CA certs, and NFS export paths. Keyed under `triliovault_backup_targets:` list. Loaded by `sunbeam-canonical/test/01_create_backup_targets.sh`. |
| `setups.yaml` | SSH access details for all lab/test environments (RHOSO18, Canonical, Sunbeam build server). Always check here before asking for server access. |
| `license_trilio.txt` | TrilioVault license file used during test installs (`juju attach-resource trilio-wlm-k8s license=...`). |
| `package_repo_urls.yaml.txt` | APT/PyPI repo URL reference (currently empty). |

---

## Steps to fix a jira.
1. In current directory, we have cloned all the repos.
- https://github.com/shyam-biradar/triliovault-cfg-scripts

2. Read the jira, collect all data including target release, in which branch we need to work and raise PR against which branch, summary of the jira, on which openstack distro we are getting the issue, what is the setup details etc

3. Second, in which branch we need fix
For example, dev-maint8/6.1

**Current convention:** For all Jiras targeted at the 6.2.1 release, use the `maint/6.2` branch directly (not `dev-maint1/6.2` or `stable/6.2`).

4. Once we decide the branch, we sync our forked repo branch with upstream repo branch.

git checkout dev-maint8/6.1
git pull origin dev-maint8/6.1
git fetch upstream
git merge upstream/dev-maint8/6.1

5. Now our local branch is up to date with upstream

6. Create topic branch for give jira, for example if jira is TVAULT-7147 then topic branch would be tv7147

Sample command
git checkout -b tv7147

7. Find the root cause of the issue and present it to me

8. Once I agree, propose the fix and wait for my approval
-- If there are any changes in input yamls or deployment bundles, do not miss those

9. Once I approve the fix, add the fix
- If not approved and then iterate and find the correct approach to fix the issue.

10. Run "review" for the fix that we done. If we find any issues, present those to me and once approved, add those fixes

11. Then commit, push, create PR. always carry it all the way through: commit, push, and create the PR against upstream <BRANCH> — do not stop and wait for a separate "create PR" instruction. Never add Claude/Anthropic co-author attribution to commit messages.
Add comment to jira that PR is raised. Always share the full PR URL (e.g. `https://github.com/trilioData/triliovault-cfg-scripts/pull/1509`), both in the Jira comment and in chat — not just the PR number.

12. Build and Publish - Build necessary artifacts like charms, docker images and publish those.
-- Use existing scripts for build and publish.

13. Uninstall and clean T4O and related resources

14. Deploy latest build artifacts and write output to env/build_artifacts.yaml
-- If there are any major changes in install flow as part of this fix, ask for install document that we are going to use here and we need to update that document with changes steps, otherwise use install document for that T4O release.

15. Run skill - 't4o-test'

16. If 't4o-test' skill fails, then troubleshoot the issue and find root cause. Again we need to repeat cycle from step 
"propose the fix and get approval" from this list of tasks till we get 't4o-test' skill tests passed.

17. Add comment on jira with fix summary and PR link. Tag reporter of the jira.

18. Update related confluence page of install or upgrade for any changes in install, upgrade steps.
-- You need to mention these changes on jira as well. If there are not changes in install steps from a end user perspective, you can skip this step.

18. Then we need to conclude the fix and present summary of the fix with build artifacts details in tabular format and full PR link to me on screen.

19. **Update CLAUDE.md** — After completing the fix, update the relevant CLAUDE.md file(s) with any non-obvious knowledge discovered during the fix. See the "CLAUDE.md Maintenance Guidelines" section below.


