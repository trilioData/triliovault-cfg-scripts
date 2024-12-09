#!/bin/bash
set -ex
COMMAND="${@:-start}"

function start () {
  # Start workloadmgr workloads service
  /usr/bin/python3 /usr/bin/workloadmgr-workloads \
     --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
     --config-file=/tmp/pod-shared-triliovault-wlm-workloads/triliovault-wlm-dynamic.conf

}

function stop () {
  kill -TERM 1
}

$COMMAND
