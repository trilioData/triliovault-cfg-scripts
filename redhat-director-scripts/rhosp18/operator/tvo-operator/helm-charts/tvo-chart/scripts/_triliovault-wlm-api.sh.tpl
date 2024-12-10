#!/bin/bash
set -ex

COMMAND="${@:-start}"

function start () {
{{- $vaultDataDir := "/var/lib/nova/triliovault-mounts" }}
{{- range .Values.triliovault_backup_targets }}
  {{- if eq .backup_target_type "nfs" }}
    {{- $nfsShare := .nfs_shares }}
    {{- $nfsParts := splitList ":" $nfsShare }}
    {{- $nfsDir := index $nfsParts 1 }}
    {{- $base64MountPoint := (b64enc $nfsDir) }}
    {{- $nfsOptions := .nfs_options }}
mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf mount -t nfs {{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}
  {{- end }}
{{- end }}

  
  # Start httpd in background
  httpd -k start

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start httpd service: $status"
    exit $status
  fi

  # Start workloadmgr api service
  /usr/bin/python3 /usr/bin/workloadmgr-api \
     --config-file=/etc/triliovault-wlm/triliovault-wlm.conf \
     --config-file=/tmp/pod-shared-triliovault-wlm-api/triliovault-wlm-dynamic.conf

  status=$?
  if [ $status -ne 0 ]; then
    echo "Failed to start tvault workloadmgr service: $status"
    exit $status
  fi
}

function stop () {
  kill -TERM 1
}

$COMMAND
