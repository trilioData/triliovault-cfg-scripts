[DEFAULT]
api_paste_config = /etc/triliovault-wlm/api-paste.ini
{{- $enabledBackends := "" }}
{{- range $index, $element := .Values.triliovault_backup_targets }}
{{- if $index }}
{{- $enabledBackends = printf "%s,%s" $enabledBackends $element.backup_target_name }}
{{- else }}
{{- $enabledBackends = $element.backup_target_name }}
{{- end }}
{{- end }}
enabled_backends = {{ $enabledBackends }}
api_workers = 4
cloud_admin_role = admin
compute_driver = libvirt.LibvirtDriver
config_status = configured
glance_api_version = 2
global_job_scheduler_override = false
helper_command = sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf privsep-helper 
keystone_auth_version = 3
log_config_append = /etc/triliovault-wlm/wlm_logging.conf
max_wait_for_upload = 48
neutron_api_insecure = false

osapi_workloads_listen_port = 8780
region_name_for_services = "{{ .Values.keystone.common.region_name }}"
rootwrap_config = /etc/triliovault-wlm/rootwrap.conf
sql_connection = "mysql+pymysql://{{- .Values.database.wlm_api.user -}}:{{- .Values.database.wlm_api.password -}}@{{- .Values.database.common.host -}}:{{- .Values.database.common.port -}}/{{- .Values.database.wlm_api.database }}"
state_path = /opt/stack/data/workloadmgr
taskflow_max_cache_size = 1024
transport_url = "rabbit://{{- .Values.rabbitmq.wlm_api.user -}}:{{- .Values.rabbitmq.wlm_api.password -}}@{{- .Values.rabbitmq.common.host -}}:{{- .Values.rabbitmq.common.port -}}/{{- .Values.rabbitmq.wlm_api.vhost }}"
trustee_role  = "{{ .Values.common.trustee_role }}"
use_syslog = false
vault_data_directory = /var/lib/nova/triliovault-mounts
vault_data_directory_old = /var/triliovault

workloads_workers = 4

{{- range .Values.triliovault_backup_targets }}
[{{ .backup_target_name }}]
{{- if eq .backup_target_type "s3" }}
vault_storage_type = s3
vault_s3_endpoint_url = {{ .s3_endpoint_url }}
vault_s3_bucket = {{ .s3_bucket }}

{{- if .s3_bucket_object_lock_enabled }}
immutable = 1
{{- else }}
immutable = 0
{{- end }}

{{- if eq .s3_type "amazon_s3" }}
vault_storage_filesystem_export = {{ .s3_bucket }}
{{- else }}

{{- $s3_endpoint_url := .s3_endpoint_url | trimSuffix "/" }}
{{- $s3_endpoint_url_no_http := $s3_endpoint_url | replace "http://" "" }}
{{- $s3_endpoint_domain_name := $s3_endpoint_url_no_http | replace "https://" "" }}
vault_storage_filesystem_export = {{ $s3_endpoint_domain_name }}/{{ .s3_bucket }}

{{- end }}
{{- else }}
vault_storage_type = nfs
vault_storage_filesystem_export = {{ .nfs_shares }}
vault_storage_nfs_options = {{ .nfs_options }}
{{- end }}
{{- if .is_default }}
is_default = 1
{{- else }}
is_default = 0
{{- end }}
{{- end }}


[alembic]
script_location = /usr/share/workloadmgr/migrate_repo
sqlalchemy.url = mysql+pymysql://{{- .Values.database.wlm_api.user -}}:{{- .Values.database.wlm_api.password -}}@{{- .Values.database.common.host -}}:{{- .Values.database.common.port -}}/{{- .Values.database.wlm_api.database }}
version_locations = /usr/share/workloadmgr/migrate_repo/versions
[barbican]
encryption_support = true
[clients]
client_retry_limit = 3
endpoint_type  = internal
#insecure = false
cafile = /etc/pki/tls/certs/ca-bundle.crt
[filesearch]
process_timeout = 300
[global_job_scheduler]
misfire_grace_time = 600

[keystone_authtoken]
auth_url = {{ .Values.keystone.common.auth_url }}
{{- $auth_url := .Values.keystone.common.auth_url | trimSuffix "/" }}
www_authenticate_uri = "{{ $auth_url }}/v3"
admin_password = "{{ .Values.keystone.wlm_api.password }}"
admin_tenant_name = "{{ .Values.keystone.common.service_project_name }}"
admin_user = "{{ .Values.keystone.wlm_api.user }}"
auth_plugin = password
auth_type = password
auth_version = v3
{{- if .Values.keystone.common.is_self_signed_ssl_cert }}
cafile = /etc/triliovault-wlm/ca-cert.pem
{{- else }}
cafile = 
{{- end }}
project_name = {{ .Values.keystone.common.service_project_name }}
region_name = {{ .Values.keystone.common.region_name }}
service_token_roles_required = true
signing_dir = /var/cache/workloadmgr
username = {{ .Values.keystone.wlm_api.user }}
password = {{ .Values.keystone.wlm_api.password }}
memcached_servers = "{{ .Values.common.memcached_servers }}"

[s3fuse_sys_admin]
helper_command = sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf privsep-helper

