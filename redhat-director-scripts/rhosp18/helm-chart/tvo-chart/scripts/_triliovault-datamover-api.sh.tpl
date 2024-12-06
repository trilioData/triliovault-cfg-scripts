#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

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

