{{- if eq .Values.triliovault_backup_target.backup_target_type "nfs" }}
#!/bin/bash
set -e

{{- $vaultDataDir := .Values.common.vault_data_dir }}
{{- $nfsShare := .Values.triliovault_backup_target.nfs_shares }}
{{- $nfsOptions := .Values.triliovault_backup_target.nfs_options }}

# Base64 encode the NFS path to create a unique mount directory
{{- $base64MountPoint := (b64enc $nfsShare) }}

mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf mount -t nfs {{ .Values.triliovault_backup_target.nfs_server }}:{{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}

echo -e "NFS backup target mounted successfully"
tail -f /dev/null
{{- end }}