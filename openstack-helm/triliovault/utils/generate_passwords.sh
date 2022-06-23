#!/bin/bash -x

set -e

MEMCACHE_SECRET_KEY=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-74} | head -n 1`
RABBITMQ_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`

cd ../

tee > values_overrides/triliovault_passwords.yaml  << EOF
endpoints:
  identity:
    auth:
      triliovault_datamover:
        password: $KEYSTONE_DATAMOVER_PASSWORD
      triliovault_wlm:
        password: $KEYSTONE_WLM_PASSWORD
  oslo_messaging:
    auth:
      triliovault_wlm:
        password: $RABBITMQ_WLM_PASSWORD
  oslo_db_triliovault_datamover:
    auth:
      triliovault_datamover:
        password: $DATABASE_DATAMOVER_PASSWORD
  oslo_db_triliovault_wlm:
    auth:
      triliovault_wlm:
        password: $DATABASE_WLM_PASSWORD
  oslo_cache:
    auth:
      memcache_secret_key: $MEMCACHE_SECRET_KEY
EOF

echo "Output written to ../values_overrides/triliovault_passwords.yaml"
