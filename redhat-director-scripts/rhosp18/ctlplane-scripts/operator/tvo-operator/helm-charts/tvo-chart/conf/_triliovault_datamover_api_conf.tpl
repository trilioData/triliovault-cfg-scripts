[DEFAULT]
dmapi_workers = {{ .Values.common.dmapi_workers }}

dmapi_enabled_ssl_apis =
dmapi_listen_port = 8783
dmapi_enabled_apis = dmapi
bindir = /usr/bin
instance_name_template = instance-%08x
rootwrap_config = /etc/triliovault-datamover/rootwrap.conf
log_config_append = /etc/triliovault-datamover/datamover_api_logging.conf


[wsgi]
ssl_cert_file = 
ssl_key_file =
api_paste_config = /etc/triliovault-datamover/api-paste.ini

[keystone_authtoken]
memcached_servers = {{ .Values.common.memcached_servers }}
signing_dir = /var/cache/dmapi
{{- if .Values.keystone.common.is_self_signed_ssl_cert }}
cafile = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
{{- else }}
cafile =
{{- end }}
project_domain_name = {{ .Values.keystone.common.service_project_domain_name }}
project_name = {{ .Values.keystone.common.service_project_name }}
user_domain_name = {{ .Values.keystone.common.service_project_domain_name }}
username = {{ .Values.keystone.datamover_api.user }}
auth_url = {{ .Values.keystone.common.auth_url }}
auth_type = password
auth_uri = {{ .Values.keystone.common.auth_uri }}

[oslo_messaging_rabbit]
ssl = {{ .Values.rabbitmq.common.ssl }}
ssl_ca_file = /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
rabbit_quorum_queue = {{ .Values.rabbitmq.cluster.rabbit_quorum_queue }}
amqp_durable_queues = {{ if .Values.rabbitmq.cluster.rabbit_quorum_queue }}true{{ else }}false{{ end }}

[oslo_messaging_notifications]
driver = {{ .Values.rabbitmq.common.driver }}

[oslo_middleware]
enable_proxy_headers_parsing = {{  .Values.common.oslo_enable_proxy_headers_parsing }}
