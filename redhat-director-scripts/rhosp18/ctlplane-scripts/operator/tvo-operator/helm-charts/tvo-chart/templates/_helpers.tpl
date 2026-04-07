{{- define "to_ini" -}}
{{- range $section, $pairs := . -}}
[{{ $section }}]
{{- range $key, $value := $pairs }}
{{ $key }} = {{ $value }}
{{- end }}
{{ end -}}
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
