# Failure modes — symptom → root cause

Match the symptom, then state the cause. Do not relay the error string alone.

## The two that mislead you most

| Symptom | Root cause |
|---|---|
| `trust-create` reports success but `trust-list` is empty | The CLI exits **0 even on HTTP 500** — cliff/cmd2 swallows the status, so the charm actions wrapping it also report success. Usually the WLM `job` table is missing its audit columns (`created_at`/`updated_at`/`deleted_at`/`deleted`/`version`/`progress`), so every job-creating call fails with `(1054, "Unknown column 'created_at' in 'field list'")`. The service still reports healthy — only job-creating calls fail. Fix: alembic migration 030 in the WLM image. |
| Backup target created but shows `offline` | Credential fetch failed. Check the `secret_ref` resolves, and that nothing appended `/payload` to it — WLM appends that itself, so a stored `.../payload` becomes `.../payload/payload` and 404s. |

## Trust and identity

| Symptom | Root cause |
|---|---|
| `No cloud admin trust found. Please recreate using CLI` from `backup-target-create` | The trust does not exist, or `cloud_admin_user_id`/`cloud_admin_project_id` in the WLM config do not match the admin that actually holds the trust. |
| `Expecting to find domain in user` | `keystone_authtoken.user_domain_id` must be a domain **ID**, not a name. Defaults to the literal `"default"`, which is wrong wherever the service domain is a real separately-created domain (Sunbeam's `service_domain`). |
| `Invalid input for field 'identity/password/user/password': None is not of type 'string'` | The trust code path reads the legacy `keystone_authtoken.admin_user`/`admin_password` aliases, which some config templates never write. |
| `The service catalog is empty` on snapshot | The WLM service account has no Keystone `default_project_id`. Client sessions never set an explicit project scope, so Keystone auto-scopes to the account's default project — and an unscoped token has zero catalog entries. |

## Backup targets and data path

| Symptom | Root cause |
|---|---|
| S3 fails, NFS passes (`both` mode) | S3 endpoint unreachable or TLS untrusted **from the DataMover node** — check the step-1 matrix per node, not just WLM. Or the `secret_ref` points at a cluster-internal key-manager URL that compute nodes cannot reach; it must be the **public** endpoint. |
| NFS fails, S3 passes (`both` mode) | Export not mounted on the DataMover node, a stale mount, or an `nfs_mount_opts` mismatch. For Cohesity NFS, raise `timeo` and `retrans`. |
| Backup target hangs; even `ls` never returns | Stale NFS mount. The mount lives on the **k8s node's host filesystem**, not only inside the container — lazy-unmount (`umount -l`) on the host, then let the next DMS job remount. Checking the path inside the WLM pod and seeing an empty directory does not mean "not mounted". |
| HTTP 502 on snapshot creation | The DMAPI Keystone **internal** endpoint is registered as an ingress/MetalLB URL, which is unreachable from inside the cluster via hairpin NAT. It must be the direct ClusterIP service URL. |
| Permission errors moving data | `nova` UID/GID mismatch across nodes. |
| Snapshot fails after running a long time | Cinder quota exhausted. Trilio needs one extra volume per disk and two Cinder snapshots per volume, on top of what the test itself created. |

## CLI shapes that fail outright

| Symptom | Root cause |
|---|---|
| `Error: No recognized column names in ['id']. Recognized columns are ['ID', 'Name', 'Status']` | List/create views use capitalised columns; `show` views use lowercase field names. See `cli-reference.md`. |
| `badly formed hexadecimal UUID string` from `workload-create` | `--instance` takes a **bare UUID**. The `instance-id=<uuid>` form in the docs is positional-argument syntax. |
| `Invalid instance as <vm> already attached with other workload` | An instance belongs to exactly one workload. Usually a previous run created the workload but lost the ID. Adopt the existing workload by name rather than recreating. |
| `license-create` hangs forever with no output | Missing `--accept-eula`; it is blocked on a curses EULA prompt. |
| `cbreak() returned ERR` | Sunbeam only: Pebble gives the process a controlling terminal. Prefix `workloadmgr` with `setsid`. |
| `/usr/bin/env: 'bash\r': No such file or directory` | CRLF line endings from a Windows checkout. `sed -i 's/\r$//'` the copied scripts. |

## Reading the step-1 matrix

- Failing from **every** node → the target itself, or a firewall in front of it.
- Failing from **one** node → that node's DNS, routing, or CA trust.
- `reach` passes but `tls` fails → the endpoint is up; its certificate is not
  trusted there. If `backup_targets.yaml` supplies `s3_ssl_ca_cert`, this is a
  warning rather than a blocker, because the CA is passed to the target.
