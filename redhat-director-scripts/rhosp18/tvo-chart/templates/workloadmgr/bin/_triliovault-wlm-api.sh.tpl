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
{{- $vaultDataDir := "/var/lib/nova/triliovault-mounts" }}
{{- range .Values.triliovault_backup_targets }}
  {{- if eq .backup_target_type "nfs" }}
    {{- $nfsShare := .nfs_shares }}
    {{- $nfsDir := (splitList ":" $nfsShare)._1 }}
    {{- $base64MountPoint := (b64enc $nfsDir) }}
    {{- $nfsOptions := .nfs_options }}
mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf mount -t nfs {{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}
  {{- end }}
{{- end }}

  
  # Start workloadmgr api service
  /usr/bin/python3 /usr/bin/workloadmgr-api \
     --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
     --config-file=/tmp/pod-shared-triliovault-wlm-api/triliovault-wlm-ids.conf

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault contego service: $status"
    exit $status
  fi
}

function stop () {
  kill -TERM 1
}

$COMMAND
