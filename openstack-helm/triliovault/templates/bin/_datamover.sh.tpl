#!/bin/bash

{{/*
Licensed under the TrilioVault License
*/}}

{{/*

This file holds command to start TrilioVault datamover service

*/}}

set -ex


if [ ${TRILIOVAULT_BACKUP_TARGET_TYPE} == "nfs" ]
then
   exec /usr/bin/python3 /usr/bin/tvault-contego \
        --config-file=/usr/share/nova/nova-dist.conf --config-file=/etc/nova/nova.conf \
        --config-file=/etc/tvault-contego/tvault-contego.conf
elif [ ${TRILIOVAULT_BACKUP_TARGET_TYPE} == "s3" ]
   exec /usr/bin/python \
        /usr/bin/s3vaultfuse.py \
        --config-file=/etc/tvault-contego/tvault-contego.conf && \
        /usr/bin/python3 /usr/bin/tvault-contego \
        --config-file=/usr/share/nova/nova-dist.conf --config-file=/etc/nova/nova.conf \
        --config-file=/etc/tvault-contego/tvault-contego.conf
else
   echo "Invalid triliovault backup target type: ${TRILIOVAULT_BACKUP_TARGET_TYPE}. Please set correct value for variable TRILIOVAULT_BACKUP_TARGET_TYPE"
fi





