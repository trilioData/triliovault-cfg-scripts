#!/bin/bash
set -ex

COMMAND="${@:-start}"

function start () {
  # Start httpd in background
  httpd -k start

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start httpd service: $status"
    exit $status
  fi

  exec /usr/bin/python3 /usr/bin/dmapi-api \
       --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf \
       --config-file /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-dynamic.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND

