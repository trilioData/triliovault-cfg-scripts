#!/bin/bash

if [[ ! -d "/var/log/kolla/triliovault-datamover-api" ]]; then
    mkdir -p /var/log/kolla/triliovault-datamover-api
fi
if [[ $(stat -c %a /var/log/kolla/triliovault-datamover-api) != "755" ]]; then
    chmod 755 /var/log/kolla/triliovault-datamover-api
fi

. /usr/local/bin/kolla_triliovault_datamover_api_extend_start