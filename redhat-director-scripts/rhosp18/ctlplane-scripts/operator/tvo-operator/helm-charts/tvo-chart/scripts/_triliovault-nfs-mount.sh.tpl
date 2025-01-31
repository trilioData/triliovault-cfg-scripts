{{- if and (eq .Values.crdType "TVOBackupTarget") (eq .Values.triliovault_backup_target.backup_target_type "nfs") }}
#!/bin/bash
set -e

{{- $vaultDataDir := .Values.common.vault_data_dir }}
{{- if eq .Values.triliovault_backup_target.backup_target_type "nfs" }}
    {{- $nfsShare := .Values.triliovault_backup_target.nfs_shares }}
    {{- $nfsParts := splitList ":" $nfsShare }}
    {{- $nfsDir := index $nfsParts 1 }}
    {{- $base64MountPoint := (b64enc $nfsDir) }}
    {{- $nfsOptions := .Values.triliovault_backup_target.nfs_options }}
mkdir -p {{ $vaultDataDir }}/{{ $base64MountPoint }}
sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf mount -t nfs {{ $nfsShare }} {{ $vaultDataDir }}/{{ $base64MountPoint }} -o {{ $nfsOptions }}
{{- end }}
{{- end }}