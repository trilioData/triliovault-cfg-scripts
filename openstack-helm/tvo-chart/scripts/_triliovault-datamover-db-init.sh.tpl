#!/bin/bash


set -ex

mkdir -p /var/log/triliovault/datamover
chown -R nova:nova /var/log/triliovault /var/trilio
touch /tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf