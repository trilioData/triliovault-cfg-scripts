# Distro adapters

Every step of the test is identical across distros **except how you reach the
WLM service and the DataMover nodes**. All of that lives in `test/t4o_env.sh`;
the numbered scripts never invoke `kubectl`/`oc`/`docker`/`podman`/`juju`
directly. If a numbered script needs a distro branch, the abstraction is leaking.

## Detection

`detect_distro()` probes cheapest-and-most-specific first; first hit wins.
Override with `T4O_DISTRO`.

| Probe | Distro |
|---|---|
| `oc get tvocontrolplane -n trilio-openstack` succeeds | `rhoso18` |
| `juju status` lists `trilio-wlm-k8s` | `sunbeam` |
| `juju status` lists `trilio-wlm` | `canonical` |
| `docker ps` shows `triliovault_wlm_api` | `kolla` |
| `kubectl get pods -A` shows `trilio*wlm-api` | `openstack-helm` |
| `podman ps` shows `triliovault_wlm_api` | `rhosp17` |

No match means T4O is not deployed — report and stop, never deploy.

## Reaching WLM

The config file is `/etc/triliovault-wlm/triliovault-wlm.conf` on **every**
distro. It is never named `workloadmgr.conf`. Only the way in differs.

| Distro | `wlm_exec` |
|---|---|
| kolla | `docker exec triliovault_wlm_api workloadmgr …` |
| rhoso18 | `oc -n trilio-openstack exec deploy/triliovault-wlm-api -- workloadmgr …` |
| rhosp17 | `sudo podman exec triliovault_wlm_api workloadmgr …` |
| canonical | `juju ssh trilio-wlm/leader -- workloadmgr …` |
| sunbeam | `kubectl exec -n openstack trilio-wlm-k8s-0 -c trilio-wlm -- setsid workloadmgr …` |
| openstack-helm | `kubectl exec -n <ns> deploy/triliovault-wlm-api -- workloadmgr …` |

`setsid` is Sunbeam-only — see `cli-reference.md`.

## Reaching the DataMover

`dm_hosts` prints one opaque **handle** per node. What a handle is depends on the
distro, and only `dm_shell`/`dm_logs` need to know.

| Distro | Handle | `dm_shell` |
|---|---|---|
| sunbeam, canonical | Juju unit (`trilio-data-mover/18`) | `juju ssh <unit> -- <cmd>` — a machine subordinate, so it runs on the host with no container wrapper |
| kolla | compute hostname | `ssh <host> docker exec triliovault_datamover …` |
| rhoso18, rhosp17 | compute hostname | `ssh <host> sudo podman exec triliovault_datamover …` |
| openstack-helm | k8s node name | `kubectl exec <datamover-pod-on-node> …` |

This matters because the DataMover is what actually moves qcow2 data. A backup
target reachable from WLM but not from here produces a workload that creates
fine and then fails mid-snapshot.

## Cloud admin credentials

Full detail, including whether each distro deletes them after use, is on
[Cloud Admin Credentials per Distro](https://triliodata.atlassian.net/wiki/spaces/TVO/pages/5140414466).
Short version: **nothing is ever deleted** except on the two Canonical distros,
which never persist the password at all.

| Distro | Source |
|---|---|
| kolla | `/etc/kolla/triliovault-cloudrc` (Trilio's own, mode 0777), else `/etc/kolla/admin-openrc.sh` |
| rhoso18 | secret `openstack-secret` key `CloudAdminPassword` in `trilio-openstack`, falling back to the `openstack` namespace |
| rhosp17 | `/etc/triliovault-wlm/cloud_admin_rc` in the puppet config volumes, else `~/overcloudrc` |
| canonical | `juju exec --unit keystone/leader -- leader-get admin_passwd`, else `juju config keystone admin-password` |
| sunbeam | `juju run keystone/leader get-admin-account -m <model>` — **not** `get-admin-password`, which does not exist on keystone-k8s |
| openstack-helm | secret `triliovault-keystone-admin` — a complete openrc in one secret |

`OS_AUTH_URL` is always taken from the live WLM config, because that is the value
the service itself uses and so cannot drift from what we authenticate against.

The suite writes an openrc at mode 0600 and deletes it at the end. It never
prints the password — only which discovery path succeeded.

## Domains and TLS

| Distro | Notes |
|---|---|
| sunbeam | admin lives in `admin_domain`, **not** `Default`. Keystone is HTTPS with a self-signed CA, so the openstack CLI needs `--insecure`. Juju models are controller-qualified: `-m controller0/openstack`; a bare `-m openstack` fails with "model not found". |
| rhoso18 | admin domain is `Default` |
| canonical | `--insecure` typically required |

## Licence and trust

| Distro | Licence | Trust |
|---|---|---|
| canonical | `juju attach-resource trilio-wlm license=<file>` (file must have **no extension**) then `juju run trilio-wlm/leader create-license` | `juju run trilio-wlm/leader create-cloud-admin-trust password=<pw>` |
| sunbeam | copy into the pod, then `juju run trilio-wlm-k8s/leader create-license license-file-path=/tmp/license` | `juju run trilio-wlm-k8s/leader create-cloud-admin-trust password=<pw>` |
| kolla, rhoso18, rhosp17, openstack-helm | copy into the WLM container, then `workloadmgr license-create /tmp/license --accept-eula` | `workloadmgr trust-create --is_cloud_trust True admin`, 5 retries 30s apart while wlm-api is still starting |

Both charm actions wrap a CLI that exits 0 on failure, so verify with
`license-list` and `trust-list` regardless of what the action reports.

## Adding a distro

Add a branch to `detect_distro()`, `_t4o_set_distro_constants()`, and each of
`wlm_exec`, `wlm_shell`, `os_exec`, `wlm_conf`, `wlm_logs`, `dm_hosts`,
`dm_shell`, `dm_logs`, `copy_to_wlm`, `discover_cloud_admin`. Nothing in the
numbered scripts should need to change.
