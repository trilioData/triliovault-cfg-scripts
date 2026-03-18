#!/bin/bash
set -e

COMMAND="${@:-start}"

function start () {
  exec /usr/bin/python3 /usr/bin/trilio-dms-server \
       --config-file /etc/triliovault-dms/server.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND





