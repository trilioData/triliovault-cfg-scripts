#!/bin/bash
set -e

COMMAND="${@:-start}"

function start () {

  # Start workloadmgr api service
  /usr/bin/python3 /usr/bin/workloadmgr-api \
     --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
     --config-file=/tmp/pod-shared-triliovault-wlm-api/triliovault-wlm-dynamic.conf

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault workloadmgr service: $status"
    exit $status
  fi
}

function stop () {
  kill -TERM 1
}

$COMMAND
