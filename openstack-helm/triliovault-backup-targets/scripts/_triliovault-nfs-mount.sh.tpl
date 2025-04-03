{{- if eq .Values.triliovault_backup_target.backup_target_type "nfs" }}
#!/bin/bash
set -ex

{{- $vaultDataDir := .Values.common.vault_data_dir }}
{{- $nfsShare := .Values.triliovault_backup_target.nfs_shares }}
{{- $nfsOptions := .Values.triliovault_backup_target.nfs_options }}

# Base64 encode the NFS path to create a unique mount directory
{{- $base64MountPoint := (b64enc $nfsShare) }}

echo "Vault Data Dir: {{ $vaultDataDir }}"
echo "NFS Share: {{ $nfsShare }}"
echo "Base64 Mount Point: {{ $base64MountPoint }}"

mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
ls -ld {{ $vaultDataDir }}/{{ $base64MountPoint }} || echo "Directory creation failed!"
echo "Attempting to mount NFS..."
sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf mount -t nfs {{ .Values.triliovault_backup_target.nfs_server }}:{{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}
echo "NFS backup target mounted successfully"
tail -f /dev/null
{{- end }}