#!/bin/bash

set -ex

## datamover api conf file for my_ip parameter
chown -R dmapi:dmapi /var/log/triliovault
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf << EOF
[DEFAULT]
dmapi_link_prefix = http://0.0.0.0:8784
dmapi_listen = 0.0.0.0
my_ip = 0.0.0.0
EOF


