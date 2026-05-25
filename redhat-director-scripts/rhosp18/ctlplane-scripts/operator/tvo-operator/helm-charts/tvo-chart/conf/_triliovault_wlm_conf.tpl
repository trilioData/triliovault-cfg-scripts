[DEFAULT]
api_paste_config = /etc/triliovault-wlm/api-paste.ini
enabled_backends = ""
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
state_path = /opt/stack/data/workloadmgr
taskflow_max_cache_size = 1024
trustee_role  = {{ .Values.common.trustee_role }}
use_syslog = false
vault_data_directory = {{ .Values.common.vault_data_dir }}
vault_data_directory_old = /var/triliovault

workloads_workers = 4

[alembic]
script_location = /usr/share/workloadmgr/migrate_repo
version_locations = /usr/share/workloadmgr/migrate_repo/versions
[barbican]
encryption_support = true
[clients]
client_retry_limit = 3
endpoint_type  = internal
cafile = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
[filesearch]
process_timeout = 300
[global_job_scheduler]
misfire_grace_time = 600

[keystone_authtoken]
auth_url = {{ .Values.keystone.common.auth_url }}
{{- $auth_url := .Values.keystone.common.auth_url | trimSuffix "/" }}
www_authenticate_uri = {{ $auth_url }}/v3

admin_tenant_name = {{ .Values.keystone.common.service_project_name }}
admin_user = {{ .Values.keystone.wlm_api.user }}
auth_plugin = password
auth_type = password
auth_version = v3
{{- if .Values.keystone.common.is_self_signed_ssl_cert }}
cafile = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
{{- else }}
cafile = 
{{- end }}
project_name = {{ .Values.keystone.common.service_project_name }}
region_name = {{ .Values.keystone.common.region_name }}
service_token_roles_required = true
signing_dir = /var/cache/workloadmgr
username = {{ .Values.keystone.wlm_api.user }}
memcached_servers = {{ .Values.common.memcached_servers }}

[s3fuse_sys_admin]
helper_command = sudo /usr/bin/workloadmgr-rootwrap /etc/triliovault-wlm/rootwrap.conf privsep-helper

[oslo_messaging_rabbit]
ssl = {{ .Values.rabbitmq.common.ssl }}
ssl_ca_file = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
rabbit_quorum_queue = {{ .Values.rabbitmq.cluster.rabbit_quorum_queue }}
amqp_durable_queues = {{ if .Values.rabbitmq.cluster.rabbit_quorum_queue }}true{{ else }}false{{ end }}

