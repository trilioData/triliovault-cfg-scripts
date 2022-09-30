#!/bin/bash -x

set -e

MEMCACHE_SECRET_KEY=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-74} | head -n 1`
RABBITMQ_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATABASE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_DATAMOVER_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
KEYSTONE_WLM_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
TRILIOVAULT_DATABASE_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`


cd ../

tee > ansible/triliovault_passwords.yml  << EOF

triliovault_database_password: $TRILIOVAULT_DATABASE_PASSWORD
## Passwords for triliovault service's keystone, database, rabbitmq users
datamover_api_keystone_user_password: $KEYSTONE_DATAMOVER_PASSWORD
datamover_api_database_user_password: $DATABASE_DATAMOVER_PASSWORD=
wlm_api_keystone_user_password: $KEYSTONE_WLM_PASSWORD
wlm_api_database_user_password: $DATABASE_WLM_PASSWORD
wlm_api_rabbitmq_password: $RABBITMQ_WLM_PASSWORD
EOF

echo "Output written to ../ansible/triliovault_passwords.yml"