#!/bin/bash

set -e

touch /tmp/pod-shared-triliovault-dms/triliovault-dms-server-dynamic.conf

if [ "$IS_RABBIT_SSL_ENABLED" = "true" ]; then
  RABBIT_SSL_ENABLED_NUM=1
else
  RABBIT_SSL_ENABLED_NUM=0
fi

tee > /tmp/pod-shared-triliovault-dms/triliovault-dms-server-dynamic.conf << EOF
[server]
rabbitmq_url = rabbit://${WLM_RABBIT_USER}:${WLM_RABBIT_PASSWORD}@${WLM_RABBIT_HOST}:5671/${WLM_RABBIT_VHOST}?ssl=${RABBIT_SSL_ENABLED_NUM}
EOF


