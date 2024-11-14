[composite:osapi_workloads]
use = call:workloadmgr.api:root_app_factory
/ = apiversions
/v1 = openstack_workloads_api_v1

[composite:openstack_workloads_api_v1]
use = call:workloadmgr.api.middleware.auth:pipeline_factory
noauth = faultwrap sizelimit noauth apiv1
keystone = faultwrap sizelimit authtoken keystonecontext apiv1
keystone_nolimit = faultwrap sizelimit authtoken keystonecontext apiv1

[filter:faultwrap]
paste.filter_factory = workloadmgr.api.middleware.fault:FaultWrapper.factory

[filter:noauth]
paste.filter_factory = workloadmgr.api.middleware.auth:NoAuthMiddleware.factory

[filter:sizelimit]
paste.filter_factory = oslo_middleware.sizelimit:RequestBodySizeLimiter.factory

[app:apiv1]
paste.app_factory = workloadmgr.api.v1.router:APIRouter.factory

[pipeline:apiversions]
pipeline = faultwrap osworkloadsversionapp

[app:osworkloadsversionapp]
paste.app_factory = workloadmgr.api.versions:Versions.factory

[filter:keystonecontext]
paste.filter_factory = workloadmgr.api.middleware.auth:WorkloadMgrKeystoneContext.factory

[filter:authtoken]
paste.filter_factory =  keystonemiddleware.auth_token:filter_factory
auth_protocol = {{ .Values.keystone.common.keystone_auth_protocol }}
auth_host = {{ .Values.keystone.common.keystone_auth_host }}
auth_port = {{ .Values.keystone.common.keystone_auth_port }}
admin_tenant_name = {{ .Values.keystone.common.service_project_name }}
project_name = {{ .Values.keystone.common.service_project_name }}
admin_user = {{ .Values.keystone.wlm_api.user }}
admin_password = {{ .Values.keystone.wlm_api.password }}
signing_dir = /var/cache/workloadmgr
insecure = False
interface = {{ .Values.keystone.keystone_interface }}
