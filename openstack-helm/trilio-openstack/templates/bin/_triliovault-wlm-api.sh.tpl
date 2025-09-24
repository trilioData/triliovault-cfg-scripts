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

  {{ if eq $backup_target_type "nfs" }}
  echo "[INFO] Starting NFS mount setup..."

  {{- $vaultDataDir := .Values.conf.wlm.DEFAULT.vault_data_directory }}
  {{- range $share := .Values.conf.triliovault.nfs.nfs_shares }}
    {{- $nfsShare := printf "%s:%s" (get $share "ip") (get $share "path") }}
    {{- $nfsDir := get $share "path" }}
    {{- $base64MountPoint := b64enc $nfsDir }}
    {{- $nfsOptions := $.Values.conf.triliovault.nfs.nfs_options }}

    echo "[INFO] Mounting NFS share {{ $nfsShare }} to {{ $vaultDataDir }}/{{ $base64MountPoint }}"
    mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
    /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf \
      mount -t nfs {{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}

  {{- end }}

  echo "[INFO] NFS mounts completed."
  {{ end }}

  {{ if eq $backup_target_type "s3" }}
  echo "[INFO] Starting S3 object store service..."
  /usr/bin/python3 /usr/bin/s3vaultfuse.py --config-file=/etc/triliovault-object-store/triliovault-object-store.conf &
  sleep 20s
  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault-object-store service: $status"
    exit $status
  fi
  {{ end }}

  echo "[INFO] Starting workloadmgr API service..."
  /usr/bin/python3 /usr/bin/workloadmgr-api \
    --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
    --config-file=/tmp/pod-shared-triliovault-wlm-api/triliovault-wlm-ids.conf

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start workloadmgr API service: $status"
    exit $status
  fi

  echo "[INFO] workloadmgr API service started successfully."
}

function stop () {
  kill -TERM 1
}

$COMMAND
