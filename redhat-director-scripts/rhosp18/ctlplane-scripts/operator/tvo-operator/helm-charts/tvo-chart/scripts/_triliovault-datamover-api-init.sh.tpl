#!/bin/bash

set -e

## datamover api conf file for my_ip parameter
chown -R dmapi:dmapi /var/log/triliovault
touch /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf

if [ "$IS_RABBIT_SSL_ENABLED" = "true" ]; then
  RABBIT_SSL_ENABLED_NUM=1
else
  RABBIT_SSL_ENABLED_NUM=0
fi

tee > /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf << EOF
[DEFAULT]
dmapi_link_prefix = http://0.0.0.0:8784
dmapi_listen = 0.0.0.0
my_ip = 0.0.0.0
transport_url = rabbit://${DMAPI_RABBIT_USER}:${DMAPI_RABBIT_PASSWORD}@${DMAPI_RABBIT_HOST}:5671/${DMAPI_RABBIT_VHOST}?ssl=${RABBIT_SSL_ENABLED_NUM}


[database]
connection = mysql+pymysql://${DMAPI_DATABASE_USER}:${DMAPI_DATABASE_PASSWORD}@${DMAPI_DATABASE_HOST}:${DMAPI_DATABASE_PORT}/${DMAPI_DATABASE_NAME}

[keystone_authtoken]
password = ${DMAPI_KEYSTONE_PASSWORD}

[oslo_messaging_notifications]
transport_url = rabbit://${DMAPI_RABBIT_USER}:${DMAPI_RABBIT_PASSWORD}@${DMAPI_RABBIT_HOST}:5671/${DMAPI_RABBIT_VHOST}?ssl=${RABBIT_SSL_ENABLED_NUM}
EOF


