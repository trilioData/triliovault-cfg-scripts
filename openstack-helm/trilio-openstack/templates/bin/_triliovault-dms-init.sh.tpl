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

# The nova base image (openstackhelm/nova) pre-seeds /var/lib/trilio as root-owned
# on the host hostPath. Since this init container runs as root (runAsUser: 0),
# ensure the host-side mount directory exists and is writable by the nova user (42424)
# before the DMS server starts. Without this, mkdir of per-target subdirs fails.
mkdir -p /var/lib/trilio/triliovault-mounts
chown -R 42424:42424 /var/lib/trilio

# Create the dynamic config handoff file.
# The NODE_NAME environment variable is injected via the Kubernetes Downward API.
# Note: rabbitmq_url is handled statically via helm-toolkit in server.conf.
tee > /tmp/pod-shared-triliovault-dms/triliovault-dms-server-dynamic.conf << EOF
[server]
node_id = ${NODE_NAME}
EOF
