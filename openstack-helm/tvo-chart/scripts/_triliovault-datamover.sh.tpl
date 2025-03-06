#!/bin/bash

set -ex

COMMAND="${@:-start}"

function start () {

    # Start triliovault datamover service
    
    /usr/bin/python3 /usr/bin/tvault-contego \
    --config-file=/etc/nova/nova.conf \
    --config-file=/etc/triliovault-datamover/triliovault-datamover.conf \
    --config-file=/tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf

    status=$?
    if [ $status -ne 0 ]; then
    echo "Failed to start tvault contego service: $status"
    exit $status
    fi

}

function stop () {
    kill -TERM 1
}

$COMMAND