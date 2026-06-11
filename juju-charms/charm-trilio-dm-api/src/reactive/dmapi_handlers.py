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
    with charm.provide_charm_instance() as charm_class:
        charm_class.render_with_interfaces(args)
        charm_class.assess_status()

    # Render DMS client config for DMAPI using WLM DB config options
    amqp = reactive.endpoint_from_flag('amqp.available')
    charm_config = hookenv.config()
    wlm_db_host = charm_config.get('wlm-db-host', '')
    wlm_db_password = charm_config.get('wlm-db-password', '')
    if amqp and wlm_db_host and wlm_db_password:
        amqp_username = amqp.username()
        amqp_password = amqp.password()
        amqp_host = amqp.private_address()
        amqp_port = amqp.ssl_port() or 5672
        amqp_vhost = amqp.vhost()
        transport_url = f"rabbit://{amqp_username}:{amqp_password}@{amqp_host}:{amqp_port}/{amqp_vhost}"

        wlm_db_user = charm_config.get('wlm-db-user', 'workloadmgr')
        wlm_db_port = charm_config.get('wlm-db-port', 3306)
        wlm_db_name = charm_config.get('wlm-db-name', 'workloadmgr')
        db_url = f"mysql+pymysql://{wlm_db_user}:{wlm_db_password}@{wlm_db_host}:{wlm_db_port}/{wlm_db_name}"

        root_uid = pwd.getpwnam('root').pw_uid
        nova_gid = grp.getgrnam('nova').gr_gid

        dms_conf_dir = '/etc/triliovault-dms'
        os.makedirs(dms_conf_dir, exist_ok=True)
        os.makedirs(os.path.join(dms_conf_dir, 'client.conf.d'), exist_ok=True)
        os.chown(dms_conf_dir, root_uid, nova_gid)

        dms_client_context = {
            'rabbitmq_url': transport_url,
            'db_url': db_url,
        }
        dms_client_conf_path = os.path.join(dms_conf_dir, 'client.conf.d', 'dmapi.conf')
        render(
            source='triliovault-dms-client.conf',
            target=dms_client_conf_path,
            context=dms_client_context,
        )
        os.chmod(dms_client_conf_path, 0o640)
        os.chown(dms_client_conf_path, root_uid, nova_gid)
        hookenv.log("DMS client config rendered for dmapi.")
    else:
        hookenv.log("Skipping DMS client config: wlm-db-host or wlm-db-password not set.")

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
