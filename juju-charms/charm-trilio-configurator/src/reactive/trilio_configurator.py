from charms.reactive import when_not, set_flag, hook
from charmhelpers.contrib import ansible
from keystoneauth1 import identity as keystone_identity
from keystoneauth1 import session as keystone_session
from keystoneclient.v3 import client as keystone_client

from charmhelpers.core.hookenv import (
    config,
    log,
    status_set,
    relation_ids,
    relation_get,
    related_units,
)


config = config()


@hook('identity-admin-relation-joined')
def get_keystone_admin():
    try:
        rid = relation_ids('identity-admin')[0]
        units = related_units(rid)
        rdata = relation_get(rid=rid, unit=units[0])
        auth = keystone_identity.Password(
            auth_url='{}://{}:{}/'.format(
                         rdata.get('service_protocol'),
                         rdata.get('service_hostname'),
                         rdata.get('service_port')),
            user_domain_name=rdata.get('service_user_domain_name'),
            username=rdata.get('service_username'),
            password=rdata.get('service_password'),
            project_domain_name=rdata.get('service_project_domain_name'),
            project_name=rdata.get('service_tenant_name'),
            )
        sess = keystone_session.Session(auth=auth)

        keystone = keystone_client.Client(session=sess)
        dm = keystone.endpoints.list(
              keystone.services.list(name='dmapi')[0].id)
        ks = keystone.endpoints.list(
              keystone.services.list(name='keystone')[0].id)
        dm_endpoints = {}
        for i in dm:
            dm_endpoints[i.interface] = i.url

        keystone_endpoints = {}
        for i in ks:
            keystone_endpoints[i.interface] = i.url

        roles_list = keystone.roles.list()
        roles = [i.name for i in roles_list]

        config['tv-os-username'] = rdata.get('service_username')
        config['tv-os-password'] = rdata.get('service_password')
        config['tv-os-domain-id'] = keystone.domains.list(
                                     name=rdata.get(
                                      'service_user_domain_name'))[0].id
        config['tv-os-tenant-name'] = rdata.get('service_tenant_name')
        config['tv-os-region-name'] = rdata.get('service_region')
        config['tv-keystone-admin-url'] = keystone_endpoints.get('admin')
        config['tv-keystone-public-url'] = keystone_endpoints.get('public')
        config['tv-dm-endpoint'] = dm_endpoints.get('internal')
        config['tv-os-trustee-role'] = config['tv-os-trustee-role']\
            if config['tv-os-trustee-role'] else roles[0]
        config.save()
        log("get_keystone_admin: Retrieved admin info")
    except Exception as ex:
        log("get_keystone_admin: Retrieval of admin info failed")
        log(ex)


@when_not('trilio-configurator.installed')
def install_configurator():
    log("Starting configuration...")
    status_set('maintenance', 'configuring tvault...')
    try:
        get_keystone_admin()
        ansible.apply_playbook('site.yaml')
        status_set('active', 'Ready...')
        set_flag('trilio-configurator.installed')
    except Exception as e:
        log("ERROR:  {}".format(e))
        log("Check the ansible log in TVault to find more info")
        status_set('blocked', 'configuration failed')
