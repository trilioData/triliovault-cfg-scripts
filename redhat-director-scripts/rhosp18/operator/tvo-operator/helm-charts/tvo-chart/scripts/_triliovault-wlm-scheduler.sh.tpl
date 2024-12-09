#!/bin/bash
set -ex

COMMAND="${@:-start}"

function start () {
  # Start workloadmgr scheduler service
  /usr/bin/python3 /usr/bin/workloadmgr-scheduler \
      --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
      --config-file=/tmp/pod-shared-triliovault-wlm-scheduler/triliovault-wlm-dynamic.conf

}

function stop () {
  kill -TERM 1
}

$COMMAND

