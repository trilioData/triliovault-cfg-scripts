export OS_AUTH_URL="{{- .Values.keystone.common.auth_uri -}}"
export OS_REGION_NAME="{{- .Values.keystone.common.region_name -}}"

export OS_USERNAME="{{- .Values.keystone.common.cloud_admin_user_name -}}"
export OS_PASSWORD="{{- .Values.keystone.common.cloud_admin_user_password -}}"

export OS_PROJECT_NAME="{{- .Values.keystone.common.cloud_admin_project_name -}}"
export OS_PROJECT_ID="{{- .Values.keystone.common.cloud_admin_project_id -}}"

export OS_USER_DOMAIN_NAME="{{- .Values.keystone.common.cloud_admin_domain_name -}}"

export OS_INTERFACE="{{- .Values.keystone.keystone_interface -}}"

{{- if .Values.keystone.common.is_self_signed_ssl_cert }}

export OS_CACERT=/etc/pki/tls/certs/openstack-ca-cert.pem

{{- end }}

export OS_IDENTITY_API_VERSION=3
unset OS_TENANT_ID
unset OS_TENANT_NAME

