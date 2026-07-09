#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
*/}}

set -ex

# The /run directory is a tmpfs, so the DMS mount directories must be recreated
# upon pod startup and owned by the nova user (42424 in Helm).
mkdir -p /run/dms/s3 /run/dms/locks
chown -R 42424:42424 /run/dms

# The nova base image (openstackhelm/nova) leaves host-mounted directories root-owned.
# Since this init container runs as root (runAsUser: 0), ensure both the mount
# directory and the log directory are owned by the nova user (42424) before the
# DMS server starts:
#   - /var/lib/trilio/triliovault-mounts: DMS creates per-backup-target subdirs here;
#     without correct ownership the mkdir call fails with "Failed to create mount directory".
#   - /var/log/triliovault: DMS server writes runtime logs here; root ownership
#     prevents the nova process from writing any log output.
mkdir -p /var/lib/trilio/triliovault-mounts
mkdir -p /var/log/triliovault
chown -R 42424:42424 /var/lib/trilio /var/log/triliovault
chmod 775 /var/lib/trilio/triliovault-mounts

# Create the dynamic config handoff file.
# The NODE_NAME environment variable is injected via the Kubernetes Downward API, but WLM routes using FQDN.
# We use hostname -f instead of NODE_NAME to ensure the queue name matches WLM's target precisely.
# Note: rabbitmq_url is handled statically via helm-toolkit in server.conf.
tee > /tmp/pod-shared-triliovault-dms/triliovault-dms-server-dynamic.conf << EOF
[server]
node_id = $(hostname -s)
EOF
