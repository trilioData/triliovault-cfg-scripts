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
  # TV-7402: Inject missing mount decorator for vast_instance
  sed -i 's/    def vast_instance(self, context, instance_uuid, params):/    @send_dms_mount_backup_target_request\n    def vast_instance(self, context, instance_uuid, params):/g' /usr/lib/python3/dist-packages/dmapi/api/openstack/api.py
  exec /var/lib/openstack/bin/python3 /usr/bin/dmapi-api \
       --config-file /etc/triliovault-datamover/triliovault-datamover-api.conf \
       --config-file /tmp/pod-shared-triliovault-datamover-api/triliovault-datamover-api-my-ip.conf
}

function stop () {
  kill -TERM 1
}

$COMMAND

