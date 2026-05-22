# triliovault-cfg-scripts — CLAUDE.md

## Introduction
T4O is shortform for Trilio for OpenStack product
In triliovault-cfg-scripts repo we keep all deployment scripts to deploy and upgrade T4O on different OpenStack distributions clouds like RedHat OpenStack, Kolla Ansible OpenStack, Mirantis OpenStack, Canonical OpenStack etc.
You need to understand openstack architecture to work on this project
https://www.openstack.org/software/

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
├── juju-charms/                    # Juju charm bundles (Canonical OpenStack)
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
-- We have designed four juju charms. 1. dmapi charm 2. data-mover charm 3. wlm charm 4. horizon plugin charm
-- We keep all charms on charmhub
-- Refer all juju syntaxes for development of these charms



---
## Deployment Platforms

| Directory | Platform | Method | OpenStack Versions |
|-----------|----------|--------|--------------------|
| `ansible/` | Generic OpenStack | Ansible roles | Any |
| `kolla-ansible/` | Kolla OpenStack | Ansible + Kolla | Zed, Antelope, Bobcat |
| `openstack-helm/` | OpenStack Helm / MOSK | Helm charts | Antelope, Bobcat, Epoxy |
| `juju-charms/` | Canonical OpenStack | Juju charms | Yoga, Antelope, Bobcat, Caracal |
| `redhat-director-scripts/rhosp16/` | RHOSP 16 | Puppet + Heat | Queens |
| `redhat-director-scripts/rhosp17/` | RHOSP 17 | Puppet + Heat | Wallaby |
| `redhat-director-scripts/rhosp18/` | RHOSO 18 | Operator + Ansible | RHOSO 18.0 |
| `tripleo/` | TripleO | Puppet + Heat | Train, Wallaby |



