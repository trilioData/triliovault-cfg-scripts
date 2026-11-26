{{- define "to_ini" -}}
{{- range $section, $pairs := . -}}
[{{ $section }}]
{{- range $key, $value := $pairs }}
{{ $key }} = {{ $value }}
{{- end }}
{{ end -}}
{{- end -}}


{{- define "tvo.ini_value" -}}
{{- if kindIs "slice" . -}}
{{- join "," . -}}
{{- else if kindIs "invalid" . -}}
{{- else if and (kindIs "float64" .) (eq . (floor .)) -}}
{{- int64 . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}


{{- define "tvo.ini_merge" -}}
{{- $overrides := .overrides | default dict -}}
{{- if not $overrides -}}
{{- .base -}}
{{- else -}}
{{- $out := list -}}
{{- $blanks := list -}}
{{- $section := "" -}}
{{- $seen := dict -}}
{{- $applied := dict -}}
{{- range $raw := splitList "\n" .base -}}
{{- $line := trimSuffix "\r" $raw -}}
{{- if regexMatch `^\s*\[[^\]]+\]\s*$` $line -}}
{{- range $key, $value := (get $overrides $section | default dict) -}}
{{- if not (hasKey $applied (printf "%s/%s" $section $key)) -}}
{{- $out = append $out (printf "%s = %s" $key (include "tvo.ini_value" $value)) -}}
{{- end -}}
{{- end -}}
{{- $out = concat $out $blanks -}}
{{- $blanks = list -}}
{{- $section = $line | trim | trimPrefix "[" | trimSuffix "]" | trim -}}
{{- $_ := set $seen $section true -}}
{{- $out = append $out $line -}}
{{- else if eq (trim $line) "" -}}
{{- $blanks = append $blanks $line -}}
{{- else -}}
{{- $out = concat $out $blanks -}}
{{- $blanks = list -}}
{{- $key := "" -}}
{{- if regexMatch `^\s*[^#;\s][^=]*=` $line -}}
{{- $key = (splitn "=" 2 $line)._0 | trim -}}
{{- end -}}
{{- $sectionOverrides := get $overrides $section | default dict -}}
{{- if and $key (hasKey $sectionOverrides $key) -}}
{{- $out = append $out (printf "%s = %s" $key (include "tvo.ini_value" (get $sectionOverrides $key))) -}}
{{- $_ := set $applied (printf "%s/%s" $section $key) true -}}
{{- else -}}
{{- $out = append $out $line -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $key, $value := (get $overrides $section | default dict) -}}
{{- if not (hasKey $applied (printf "%s/%s" $section $key)) -}}
{{- $out = append $out (printf "%s = %s" $key (include "tvo.ini_value" $value)) -}}
{{- end -}}
{{- end -}}
{{- $out = concat $out $blanks -}}
{{- range $name, $pairs := $overrides -}}
{{- if not (hasKey $seen $name) -}}
{{- $out = append $out "" -}}
{{- $out = append $out (printf "[%s]" $name) -}}
{{- range $key, $value := ($pairs | default dict) -}}
{{- $out = append $out (printf "%s = %s" $key (include "tvo.ini_value" $value)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join "\n" $out -}}
{{- end -}}
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
snapshot:snapshot_bulk_delete: rule:admin_or_owner
snapshot:snapshot_cancel: rule:admin_or_owner
snapshot:snapshot_delete: rule:admin_or_owner
snapshot:snapshot_dismount: rule:admin_or_owner
snapshot:snapshot_get_all: rule:admin_or_owner
snapshot:snapshot_mount: rule:admin_or_owner
snapshot:snapshot_restore: rule:admin_or_owner
snapshot:snapshot_show: rule:admin_or_owner
workload:add_node: rule:admin_api
workload:backup_target_create: rule:admin_api
workload:backup_target_delete: rule:admin_api
workload:backup_target_set_default: rule:admin_api
workload:backup_target_type_create: rule:admin_api
workload:backup_target_type_delete: rule:admin_api
workload:backup_target_type_update: rule:admin_api
workload:backup_target_update: rule:admin_api
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
workload:get_import_reassign_jobs: rule:admin_api
workload:delete_jobs: rule:admin_api
workload:eula_create: rule:admin_api
workload:license_check: rule:admin_api
workload:license_create: rule:admin_api
workload:license_list: rule:admin_api
workload:policy_apply: rule:admin_api
workload:policy_assignment_list: rule:admin_api
workload:policy_clone: rule:admin_api
workload:policy_create: rule:admin_api
workload:policy_delete: rule:admin_api
workload:policy_field_create: rule:admin_api
workload:policy_remove: rule:admin_api
workload:policy_reassign_workloads: rule:admin_api
workload:policy_update: rule:admin_api
workload:project_policy_clone: rule:admin_or_owner
workload:project_policy_create: rule:admin_or_owner
workload:project_policy_delete: rule:admin_or_owner
workload:project_policy_update: rule:admin_or_owner
workload:project_policy_workloads: rule:admin_or_owner
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
