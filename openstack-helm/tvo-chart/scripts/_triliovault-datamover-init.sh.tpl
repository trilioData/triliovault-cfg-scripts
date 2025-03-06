#!/bin/bash



set -ex

mkdir -p /var/log/triliovault/triliovault-datamover
chown -R nova:nova /var/log/triliovault /var/lib/trilio
touch /tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf
