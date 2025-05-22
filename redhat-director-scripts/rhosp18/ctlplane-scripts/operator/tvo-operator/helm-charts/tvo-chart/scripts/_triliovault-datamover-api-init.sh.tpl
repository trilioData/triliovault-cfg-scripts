#!/bin/bash

set -e

## datamover api conf file for my_ip parameter
chown -R dmapi:dmapi /var/log/triliovault
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf << EOF
[DEFAULT]
dmapi_link_prefix = http://0.0.0.0:8784
dmapi_listen = 0.0.0.0
my_ip = 0.0.0.0

[database]
connection = mysql+pymysql://${DMAPI_DATABASE_USER}:${DMAPI_DATABASE_PASSWORD}@${DMAPI_DATABASE_HOST}:${DMAPI_DATABASE_PORT}/${DMAPI_DATABASE_NAME}

[keystone_authtoken]
password = ${DMAPI_KEYSTONE_PASSWORD}

[oslo_messaging_rabbit]
rabbit_password = ${DMAPI_RABBIT_PASSWORD}

EOF


