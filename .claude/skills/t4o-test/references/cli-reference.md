# workloadmgr CLI reference

Syntax from [docs.trilio.io](https://docs.trilio.io/openstack/t4o-6.x/), plus the
shapes that fail outright and are not obvious from the docs.

## Where it runs

`workloadmgr` **must** run inside the WLM service. The
`python3-workloadmgrclient` plugin ships only in the WLM image — never on a
bastion, build host, or jump box. Use `wlm_exec` from `test/t4o_env.sh`.

On **Sunbeam only**, prefix it with `setsid`. Pebble (container PID 1) hands the
process a controlling terminal, and cliff/cmd2 then opens `/dev/tty` and calls
`curses.cbreak()`, which fails with `cbreak() returned ERR`.

## Column naming is inconsistent, and getting it wrong fails the command

This is the single most time-wasting trap in this CLI.

| Command | View | Column names |
|---|---|---|
| `workload-list`, `workload-create`, `snapshot-list`, `backup-target-list`, `backup-target-type-list` | table | Capitalised: `ID`, `Name`, `Status` |
| `workload-show`, `snapshot-show` | detail | lowercase: `id`, `status`, `progress_percent`, … |

Asking for the wrong one returns an error, not an empty value:

```
Error: No recognized column names in ['id'].
Recognized columns are ['ID', 'Name', 'Status'].
```

For IDs, the robust move is not to pass `-c` at all — capture the output and
extract the UUID, which is unambiguous because neither view contains another.

## Objects: backup target vs backup target type

Confusing these breaks workload creation.

| Object | Identified by | Command |
|---|---|---|
| **backup target** — the storage | `Backend Endpoint` (the filesystem export or `host/bucket`). **No name column.** | `backup-target-list` |
| **backup target type (BTT)** — the named abstraction over one target | `Name`, created via `--btt-name` | `backup-target-type-list` |

`workload-create --backup-target-type` consumes the **BTT name**, and that name
is frequently not the one in `backup_targets.yaml` — a lab may register an
export as `BT_NFS_LAB` while the yaml calls it `BT_NFS`. Resolve it: find the
backup target whose `Backend Endpoint` matches, then find the BTT pointing at
that target ID.

Never split an NFS export on `/` to derive server or path — that mangles exports
whose path contains slashes (TVAULT-7419). Match the whole string.

## Commands

### Licence

```
workloadmgr license-create <license_file> --accept-eula
workloadmgr license-list
```

`--accept-eula` is **required**; without it `license-create` blocks forever on a
curses EULA prompt. Verify with `license-list` — never by exit code.

Canonical and Sunbeam wrap this in charm actions instead:

```
juju attach-resource trilio-wlm license=<file>      # file must have NO extension
juju run trilio-wlm/leader create-license
juju run trilio-wlm-k8s/leader create-license license-file-path=/tmp/license
```

### Trust

```
workloadmgr trust-create --is_cloud_trust True admin
workloadmgr trust-list
workloadmgr trust-show <trust_id>
workloadmgr trust-delete <trust_id>
```

Create it as the same user and tenant that configured Trilio; the role is
`admin`.

> `trust-create` **exits 0 even when the API returns HTTP 500.** The only proof
> is a non-empty `trust-list`. IDs render as `trust-<uuid>`, not a bare UUID, so
> a UUID-shaped row regex silently matches nothing.

### Backup targets

```
workloadmgr backup-target-create --btt-name <name> --type s3 \
    --s3-endpoint-url <url> --s3-bucket <bucket> --secret-ref <ref> [--default]

workloadmgr backup-target-create --btt-name <name> --type nfs \
    --filesystem-export <server:/export> --nfs-mount-opts <opts>

workloadmgr backup-target-list
workloadmgr backup-target-type-list
```

S3 credentials go to Barbican; the target stores only a `secret_ref`:

- `payload_content_type` must be **`text/plain`** — Barbican rejects
  `application/json`. The DMS payload is JSON stored as opaque text.
- Use the **public** key-manager endpoint from the Keystone catalog. Compute
  nodes cannot reach cluster-internal ClusterIPs, and the DataMover is what
  resolves the ref at backup time.
- Store the ref exactly as Barbican returns it. WLM appends `/payload` itself.

### Workloads and snapshots

```
workloadmgr workload-create --instance <uuid> \
    --display-name <name> --backup-target-type <btt-name> --manual retention=30

workloadmgr workload-list
workloadmgr workload-show <workload_id>

workloadmgr workload-snapshot <workload_id> --full --display-name <name>
workloadmgr snapshot-list [--workload_id <id>]
workloadmgr snapshot-show <snapshot_id>
workloadmgr snapshot-delete <snapshot_id>
```

- `--instance` takes a **bare UUID**. The `instance-id=<uuid>` form in the docs
  is positional-argument syntax and fails against the flag.
- An instance belongs to **exactly one** workload. Re-creating against the same
  VM fails with `Invalid instance as <vm> already attached with other workload`.
- The backup target type is **immutable after creation** — one workload per
  target, never one retargeted.
- Snapshot status: `creating` → `uploading` → `available`; `error` is terminal.
- `workload-list`/`snapshot-list` are scoped to the authenticated project. Query
  with the same project that created them, or you get an empty list rather than
  an error.
