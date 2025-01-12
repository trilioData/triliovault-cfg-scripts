#!/bin/bash

set -ex

COMMAND="${@:-start}"

function start () {

  ## Start triliovault object store service if backup target type is s3
  /usr/bin/python3 /usr/bin/s3vaultfuse.py --config-file=/etc/triliovault-object-store/triliovault-object-store.conf
  sleep 20s
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault-object-store service: $status"
    exit $status
  fi

}

function stop () {
  kill -TERM 1
}

$COMMAND
