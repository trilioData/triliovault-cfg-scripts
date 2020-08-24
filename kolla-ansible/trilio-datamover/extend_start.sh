#!/bin/bash

if [[ ! -d "/var/log/kolla/triliovault-datamover" ]]; then
    mkdir -p /var/log/kolla/triliovault-datamover
fi
if [[ $(stat -c %a /var/log/kolla/triliovault-datamover) != "755" ]]; then
    chmod 755 /var/log/kolla/triliovault-datamover
fi