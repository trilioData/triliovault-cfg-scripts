#!/bin/bash
set -ex
COMMAND="${@:-start}"

function start () {
  exec /usr/bin/python3 /usr/bin/workloadmgr-cron \
       --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
       --config-file=/tmp/pod-shared-triliovault-wlm-cron/triliovault-wlm-dynamic.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND

