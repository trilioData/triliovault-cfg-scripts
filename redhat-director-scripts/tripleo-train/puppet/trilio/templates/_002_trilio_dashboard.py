<% if @barbican_api_enabled == true -%>
OPENSTACK_ENCRYPTION_SUPPORT = True
<% else -%>
OPENSTACK_ENCRYPTION_SUPPORT = False
<% end -%>

TRILIO_ENCRYPTION_SUPPORT = False
HORIZON_CONFIG['customization_module'] = 'dashboards.overrides