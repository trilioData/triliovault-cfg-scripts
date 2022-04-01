#!/bin/bash

{{/*
Licensed under the TrilioVault License
*/}}

set -ex
COMMAND="${@:-start}"

function start () {
  exec /usr/bin/python3 /usr/bin/dmapi-api \
        --config-file /etc/dmapi/dmapi.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND
