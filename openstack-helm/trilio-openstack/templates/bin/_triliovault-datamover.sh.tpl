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
  {{- $backup_target_type := .Values.conf.triliovault.backup_target_type }}
  {{- $distro := default "" .Values.distro }}

  {{- if eq $backup_target_type "s3" }}
  ## Start triliovault object store service
  /usr/bin/python3 /usr/bin/s3vaultfuse.py --config-file=/etc/triliovault-object-store/triliovault-object-store.conf &
  status=$?
  sleep 20s
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault-object-store service: $status"
    exit $status
  fi
  {{- end }}

  CMD="/usr/bin/python3 /usr/bin/tvault-contego \
    --config-file=/etc/nova/nova.conf"

  {{- if eq $distro "mosk" }}
  CMD+=" --config-file=/etc/nova/nova.conf.d/nova-hypervisor.conf"
  CMD+=" --config-file=/etc/nova/nova.conf.d/nova-libvirt.conf"
  {{- end }}

  CMD+=" --config-file=/etc/triliovault-datamover/triliovault-datamover.conf"
  CMD+=" --config-file=/tmp/pod-shared-triliovault-datamover/triliovault-datamover-dynamic-values.conf"

  echo "Running: $CMD"
  eval $CMD
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault contego service: $status"
    exit $status
  fi
}

function stop () {
  kill -TERM 1
  {{ if eq $backup_target_type "nfs" }}
  {{- range $share := .Values.conf.triliovault.nfs.nfs_shares }}
  {{- $share_path := get $share "path" }}
  {{- $encoded := $share_path | b64enc }}
  umount -l {{ printf "%s/%s" $.Values.conf.wlm.DEFAULT.vault_data_directory $encoded }}
  {{- end }}
  {{- end }}
}

$COMMAND
