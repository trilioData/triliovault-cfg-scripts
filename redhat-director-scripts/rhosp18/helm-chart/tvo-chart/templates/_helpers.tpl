{{- define "to_ini" -}}
{{- range $section, $pairs := . -}}
[{{ $section }}]
{{- range $key, $value := $pairs }}
{{ $key }} = {{ $value }}
{{- end }}
{{ end -}}
{{- end -}}


{{- define "to_ini_object_store" -}}
{{- $target := index . "target" -}}
{{- $vaultDataDir := "/var/lib/nova/triliovault-mounts" -}}
{{- $backupTargetMountPoint := "" -}}
{{- $vaultStorageNfsExport := "" -}}

{{- if eq $target.backup_target_type "s3" }}
  {{- if eq $target.s3_type "amazon_s3" }}
    {{- $backupTargetMountPoint = (b64enc $target.s3_bucket) }}
    {{- $vaultStorageNfsExport = $target.s3_bucket }}
  {{- else }}
    {{- $s3_endpoint_url := $target.s3_endpoint_url | trimSuffix "/" }}
    {{- $s3_endpoint_url_no_http := $s3_endpoint_url | replace "http://" "" }}
    {{- $s3DomainName := $s3_endpoint_url_no_http | replace "https://" "" }}
    {{- $cephS3Str := printf "%s/%s" $s3DomainName $target.s3_bucket }}
    {{- $backupTargetMountPoint = (b64enc $cephS3Str) }}
    {{- $vaultStorageNfsExport = $cephS3Str }}
  {{- end }}
{{- end }}

[DEFAULT]
{{- if eq $target.backup_target_type "s3" }}
vault_s3_access_key_id = {{ $target.s3_access_key }}
vault_s3_secret_access_key = {{ $target.s3_secret_key }}
vault_s3_bucket = {{ $target.s3_bucket }}
vault_s3_region_name = {{ $target.s3_region_name }}
vault_s3_auth_version = {{ $target.s3_auth_version }}
vault_s3_signature_version = {{ $target.s3_signature_version }}
vault_s3_ssl = {{ $target.s3_ssl_enabled }}
vault_s3_ssl_verify = {{ $target.s3_ssl_verify }}
vault_storage_nfs_export = {{ $vaultStorageNfsExport }}

{{- if $target.s3_bucket_object_lock_enabled }}
bucket_object_lock = true
use_manifest_suffix = true
{{- else }}
bucket_object_lock = false
use_manifest_suffix = false
{{- end }}

{{- if and $target.s3_ssl_enabled $target.s3_self_signed_cert }}
vault_s3_ssl_cert = /etc/triliovault-object-store/s3-cert-{{ $target.backup_target_name | lower }}.pem
{{- else }}
vault_s3_ssl_cert =
{{- end }}

{{- if eq $target.s3_type "ceph_s3" }}
vault_s3_endpoint_url = {{ $target.s3_endpoint_url }}
{{- else }}
vault_s3_endpoint_url =
{{- end }}
{{- else }}
vault_s3_access_key_id = 
vault_s3_secret_access_key = 
vault_s3_bucket = 
vault_s3_region_name = 
vault_s3_auth_version = 
vault_s3_signature_version = 
vault_s3_ssl = 
vault_s3_ssl_cert = 
vault_s3_endpoint_url =
{{- end }}

vault_s3_max_pool_connections = 500
vault_data_directory_old = /var/triliovault
vault_data_directory = {{ $vaultDataDir }}/{{ $backupTargetMountPoint }}
log_config_append = /etc/triliovault-object-store/object_store_logging.conf
[s3fuse_sys_admin]
helper_command = sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf privsep-helper
{{- end -}}


