#!/bin/bash
set -ex

COMMAND="${@:-start}"

function start () {

  # Start dms
  /usr/bin/python3 /usr/bin/triliovault-dms \
      --config-file=/etc/triliovault-dms/server.conf \

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start triliovault dms service: $status"
    exit $status
  fi
}

function stop () {
  kill -TERM 1
}

$COMMAND

