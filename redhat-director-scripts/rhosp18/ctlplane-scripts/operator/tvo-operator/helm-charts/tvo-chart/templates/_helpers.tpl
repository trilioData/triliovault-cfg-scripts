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
{{- $vaultDataDir := index . "Values" "common" "vault_data_dir" -}}
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

{{- if eq $target.s3_type "other_s3" }}
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



{{- define "trilio.workloadmgr.defaultPolicy" -}}
admin_api:
- - is_admin:True
admin_or_owner:
- - is_admin:True
- - project_id:%(project_id)s
context_is_admin:
- - role:admin
default:
- - rule:admin_or_owner
filesearch:search: rule:admin_or_owner
restore:restore_cancel: rule:admin_or_owner
restore:restore_delete: rule:admin_or_owner
restore:restore_get_all: rule:admin_or_owner
restore:restore_show: rule:admin_or_owner
snapshot:mounted_list: rule:admin_or_owner
snapshot:snapshot_cancel: rule:admin_or_owner
snapshot:snapshot_delete: rule:admin_or_owner
snapshot:snapshot_dismount: rule:admin_or_owner
snapshot:snapshot_get_all: rule:admin_or_owner
snapshot:snapshot_mount: rule:admin_or_owner
snapshot:snapshot_restore: rule:admin_or_owner
snapshot:snapshot_show: rule:admin_or_owner
workload:add_node: rule:admin_api
workload:config_backup: rule:admin_api
workload:config_backup_delete: rule:admin_api
workload:config_workload: rule:admin_api
workload:get_auditlog: rule:admin_api
workload:get_config_backups: rule:admin_api
workload:get_config_workload: rule:admin_api
workload:get_contego_status: rule:admin_api
workload:get_import_workloads_list: rule:admin_api
workload:get_nodes: rule:admin_api
workload:get_orphaned_workloads_list: rule:admin_api
workload:get_setting: rule:admin_or_owner
workload:get_storage_usage: rule:admin_api
workload:get_tenants_usage: rule:admin_api
workload:import_workloads: rule:admin_api
workload:license_check: rule:admin_api
workload:license_create: rule:admin_api
workload:license_list: rule:admin_api
workload:policy_apply: rule:admin_api
workload:policy_create: rule:admin_api
workload:policy_delete: rule:admin_api
workload:policy_field_create: rule:admin_api
workload:policy_remove: rule:admin_api
workload:policy_update: rule:admin_api
workload:remove_node: rule:admin_api
workload:setting_delete: rule:admin_or_owner
workload:setting_get: rule:admin_or_owner
workload:settings_create: rule:admin_or_owner
workload:settings_get: rule:admin_or_owner
workload:settings_update: rule:admin_or_owner
workload:trust_create: rule:admin_or_owner
workload:trust_delete: rule:admin_or_owner
workload:trust_get: rule:admin_api
workload:trust_list: rule:admin_or_owner
workload:workload_create: rule:admin_or_owner
workload:workload_delete: rule:admin_or_owner
workload:workload_disable_global_job_scheduler: rule:admin_api
workload:workload_enable_global_job_scheduler: rule:admin_api
workload:workload_ensure_global_job_scheduler: rule:admin_or_owner
workload:workload_get_all: rule:admin_or_owner
workload:workload_get_all_by_admin: rule:admin_api
workload:workload_get_global_job_scheduler: rule:admin_or_owner
workload:workload_modify: rule:admin_or_owner
workload:workload_reset: rule:admin_or_owner
workload:workload_show: rule:admin_or_owner
workload:workload_snapshot: rule:admin_or_owner
workload:workload_type_get_all: rule:admin_or_owner
workload:workload_type_show: rule:admin_or_owner
workload:workload_unlock: rule:admin_or_owner
workload:workloads_reassign: rule:admin_api
{{- end }}
