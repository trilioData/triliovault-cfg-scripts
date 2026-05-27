#!/bin/bash
set -ex

COMMAND="${@:-start}"

function start () {

  # Start dms with static base config + dynamic overrides (node_id, rabbitmq_url)
  /var/lib/openstack/bin/python3 /usr/bin/trilio-dms-server \
      --config-file=/etc/triliovault-dms/server.conf \
      --config-file=/tmp/pod-shared-triliovault-dms/triliovault-dms-server-dynamic.conf

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

