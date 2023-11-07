#!/bin/bash -x

set -e

MEMCACHE_SECRET_KEY=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-74} | head -n 1`
RABBITMQ_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`

cd ../

tee > environments/passwords.yaml  << EOF
parameter_defaults:

   ## Passwords for triliovault service's keystone, database, rabbitmq users
   WlmApiKeystoneUserPassword: "$KEYSTONE_WLM_PASSWORD"
   WlmApiDbUserPassword: "$DATABASE_WLM_PASSWORD"
   DatamoverApiKeystoneUserPassword: "$KEYSTONE_DATAMOVER_PASSWORD"
   DatamoverApiDbUserPassword: "$DATABASE_DATAMOVER_PASSWORD="
   WlmOsloMessagingRpcUserPassword: "$RABBITMQ_WLM_PASSWORD"
EOF

echo "Output written to ../environments/passwords.yaml"
