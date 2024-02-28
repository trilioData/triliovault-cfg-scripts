#!/bin/bash -x

set -e

WLM_API_KS_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_API_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
WLM_API_RABBITMQ_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATAMOVER_API_KS_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`
DATAMOVER_API_DB_PASSWORD=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${11:-42} | head -n 1`


cd ../

tee > ansible/triliovault_passwords.yml  << EOF
triliovault_wlm_keystone_password: $WLM_API_KS_PASSWORD
triliovault_wlm_database_password: $WLM_API_DB_PASSWORD
triliovault_wlm_rabbitmq_password: $WLM_API_RABBITMQ_PASSWORD
triliovault_datamover_keystone_password: $DATAMOVER_API_KS_PASSWORD
triliovault_datamover_database_password: $DATAMOVER_API_DB_PASSWORD=
EOF

echo "Output written to ../ansible/triliovault_passwords.yml"