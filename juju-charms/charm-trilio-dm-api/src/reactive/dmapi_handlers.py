# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import pwd
import grp

import charms_openstack.charm as charm
import charms.reactive as reactive
from charmhelpers.core.templating import render
from charmhelpers.core import hookenv
from charmhelpers.core import host

# This charm's library contains all of the handler code associated with
# dmapi
import charm.openstack.dmapi as dmapi  # noqa

charm.use_defaults(
    "charm.installed",
    "amqp.connected",
    "shared-db.connected",
    "identity-service.connected",
    "identity-service.available",  # enables SSL support
    "config.changed",
    "update-status",
    "certificates.available",
    "cluster.available",
)


@reactive.when("dmapi-db.ready")
@reactive.when("shared-db.available")
@reactive.when("identity-service.available")
@reactive.when("amqp.available")
def render_config(*args):
    """Render the configuration for charm when all the interfaces are
    available.
    """
    with charm.provide_charm_instance() as charm_class:
        charm_class.upgrade_if_available(args)

    # Pre-create log file with dmapi ownership so the service can write to it.
    # /var/log/triliovault/ is nova:nova 755 — dmapi user cannot create files there.
    log_dir = '/var/log/triliovault'
    os.makedirs(log_dir, exist_ok=True)
    dmapi_uid = pwd.getpwnam('dmapi').pw_uid
    dmapi_gid = grp.getgrnam('dmapi').gr_gid
    log_file = os.path.join(log_dir, 'triliovault-datamover-api.log')
    if not os.path.exists(log_file):
        open(log_file, 'w').close()
    os.chown(log_file, dmapi_uid, dmapi_gid)

    with charm.provide_charm_instance() as charm_class:
        charm_class.render_with_interfaces(args)
        charm_class.assess_status()

    # DMS server must not run on DMAPI nodes — only the client library is needed here.
    # python3-trilio-dms installs the systemd unit; explicitly stop and disable it.
    host.service('disable', 'trilio-dms-server')
    host.service('stop', 'trilio-dms-server')

    reactive.set_state("config.rendered")


@reactive.when("config.rendered")
def init_db():
    """Perform DB Sync"""
    with charm.provide_charm_instance() as charm_class:
        charm_class.db_sync()


@reactive.when("ha.connected")
def cluster_connected(hacluster):
    """Configure HA resources in corosync"""
    with charm.provide_charm_instance() as charm_class:
        charm_class.configure_ha_resources(hacluster)
        charm_class.assess_status()


@reactive.when('wlm-db.connected')
@reactive.when('shared-db.available')
@reactive.when('amqp.available')
def render_dms_client_config(*args):
    """Render DMS client config for dmapi using workloadmgr DB credentials from wlm-db relation."""
    wlm_db_password = None
    for rid in hookenv.relation_ids('wlm-db'):
        for unit in hookenv.related_units(rid):
            data = hookenv.relation_get(unit=unit, rid=rid)
            wlm_db_password = data.get('workloadmgr_password', '')
            if wlm_db_password:
                break

    if not wlm_db_password:
        hookenv.log("wlm-db relation has no workloadmgr_password yet, skipping DMS client config.")
        return

    mysql_host = '127.0.0.1'
    for rid in hookenv.relation_ids('shared-db'):
        for unit in hookenv.related_units(rid):
            data = hookenv.relation_get(unit=unit, rid=rid)
            if data.get('db_host'):
                mysql_host = data['db_host']
                break

    amqp = reactive.endpoint_from_flag('amqp.available')
    transport_url = (
        f"rabbit://{amqp.username()}:{amqp.password()}"
        f"@{amqp.private_address()}:{amqp.ssl_port() or 5672}/{amqp.vhost()}"
    )
    db_url = f"mysql+pymysql://workloadmgr:{wlm_db_password}@{mysql_host}:3306/workloadmgr"

    root_uid = pwd.getpwnam('root').pw_uid
    nova_gid = grp.getgrnam('nova').gr_gid

    dms_conf_dir = '/etc/triliovault-dms'
    os.makedirs(dms_conf_dir, exist_ok=True)
    os.chown(dms_conf_dir, root_uid, nova_gid)

    dms_client_conf_path = os.path.join(dms_conf_dir, 'client.conf')
    render(
        source='etc_triliovault-dms_client.conf',
        target=dms_client_conf_path,
        context={'rabbitmq_url': transport_url, 'db_url': db_url},
    )
    os.chmod(dms_client_conf_path, 0o640)
    os.chown(dms_client_conf_path, root_uid, nova_gid)
    hookenv.log("DMS client config rendered for dmapi via wlm-db relation.")


@reactive.when("shared-db.available")
@reactive.when_not("dmapi-db.ready")
def check_dmapi_db():
    db_ep = reactive.endpoint_from_flag('shared-db.available')
    if db_ep:
        if db_ep.password(prefix='dmapi'):
            reactive.set_state("dmapi-db.ready")
        else:
            with charm.provide_charm_instance() as instance:
                for db in instance.get_database_setup():
                    db_ep.configure(**db)


@reactive.when_any("config.changed.triliovault-pkg-source",
                   "config.changed.openstack-origin")
def install_source_changed():
    """Trigger re-install of charm if source configuration options change"""
    reactive.clear_flag("charm.installed")
    reactive.set_flag("upgrade.triliovault")
