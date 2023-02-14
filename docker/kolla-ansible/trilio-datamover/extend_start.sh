#!/bin/bash

if [[ ! -d "/var/log/triliovault" ]]; then
    mkdir -p /var/log/triliovault
fi
if [[ $(stat -c %a /var/log/triliovault) != "755" ]]; then
    chmod 755 /var/log/triliovault
fi
