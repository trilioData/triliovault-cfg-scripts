# Copyright 2020 Canonical Ltd
#
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
import glob
import os
import pwd
import grp
import socket
import tempfile
import subprocess
import json
import charms_openstack.charm as charm
import charms.reactive as reactive
from charmhelpers.core.templating import render
from charmhelpers.core.hookenv import config, log
from charmhelpers.core import hookenv
from charmhelpers.core import host
from charms.reactive import when, set_flag
# This charm's library contains all of the handler code for this charm
import charm.openstack.trilio_wlm as trilio_wlm  # noqa
from charm.openstack.trilio_wlm import TrilioWLMBaseCharm
import apt
import apt.progress.text
from charmhelpers.core.hookenv import (
    config,
    resource_get,
    status_set,
)
from charms.reactive import (
    hook,
    when,
    clear_flag,
    set_flag,
)

# Determine correct API port based on SSL status
from charmhelpers.contrib.openstack.context import (
    determine_api_port,
    https,
)


charm.use_defaults(
    "charm.installed",
    "amqp.connected",
    "shared-db.connected",
    "identity-service.available",  # enables SSL support
    "config.changed",
    "update-status",
    "certificates.available",
    "cluster.available",
)


def run_trilio_install_upgrade_packages(packages):
    """
    Install or upgrade the specified apt packages using the python-apt library.

    :param packages: A list of package names to install or upgrade.
    """
    set_flag('maintenance', 'Running Trilio Install Upgrade Packages')
    dpkg_opts = [
        '--option', 'Dpkg::Options::=--force-confnew',
        '--option', 'Dpkg::Options::=--force-confdef',
    ]

    cache = apt.Cache()
    cache.update()
    cache.open()

    for package_name in packages:
        pkg = cache.get(package_name)

        if pkg is None:
            print(f"Package {package_name} not found in the cache.")
            continue

        if package_name == 'workloadmgr' and cache.get('python3-shade') is None:
            # python3-shade was removed from Ubuntu Noble repos in Epoxy; install
            # shade via pip and force-install workloadmgr via dpkg to bypass the
            # unresolvable python3-shade dep without leaving apt in broken state
            print("Installing workloadmgr with python3-shade workaround (Noble)...")
            try:
                subprocess.run(['pip3', 'install', 'shade'], check=True)
                with tempfile.TemporaryDirectory() as tmpdir:
                    subprocess.run(
                        ['apt-get', 'download', 'workloadmgr'],
                        check=True, cwd=tmpdir
                    )
                    deb_files = glob.glob(os.path.join(tmpdir, 'workloadmgr*.deb'))
                    if deb_files:
                        subprocess.run(
                            ['dpkg', '--force-depends', '-i'] + deb_files,
                            check=True
                        )
                        print("workloadmgr installed/upgraded successfully.")
                    else:
                        print("workloadmgr .deb not found after apt-get download.")
            except subprocess.CalledProcessError as e:
                print(f"Failed to install/upgrade workloadmgr: {e}")
            continue

        if pkg.is_installed and pkg.is_upgradable:
            print(f"Upgrading package: {package_name}")
            try:
                subprocess.run(
                    ['sudo', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '--only-upgrade', '-y'] + dpkg_opts + [package_name],
                    check=True
                )
                print(f"Package {package_name} upgraded successfully.")
            except subprocess.CalledProcessError as e:
                print(f"Failed to upgrade package {package_name}: {e}")
        elif not pkg.is_installed:
            print(f"Installing package: {package_name}")
            try:
                subprocess.run(
                    ['sudo', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y'] + dpkg_opts + [package_name],
                    check=True
                )
                print(f"Package {package_name} installed successfully.")
            except subprocess.CalledProcessError as e:
                print(f"Failed to install package {package_name}: {e}")
        else:
            print(f"Package {package_name} is already up to date.")


@reactive.when_not('is-update-status-hook')
@reactive.when("shared-db.available")
@reactive.when("identity-service.available")
@reactive.when("amqp.available")
def render_config(*args):
    """Render the configuration for the charm when all the interfaces are available."""

    with charm.provide_charm_instance() as charm_class:
        packages_to_install = TrilioWLMBaseCharm().base_packages
        hookenv.log(f"Trilio Wlm Charm Packages: {packages_to_install}")
        current_pkg_source = hookenv.config('triliovault-pkg-source')
        is_trilio_pkg_source_changed = reactive.helpers.data_changed('triliovault-pkg-source', current_pkg_source)
        if is_trilio_pkg_source_changed or not reactive.is_state('triliovault-packages.installed'):
            run_trilio_install_upgrade_packages(packages_to_install)
            reactive.set_flag('triliovault-packages.installed')
            if os.path.exists('/lib/systemd/system/tvault-object-store.service'):
                host.service('stop', 'tvault-object-store')
                host.service('disable', 'tvault-object-store')
            # Run the DB migration now, before render_with_interfaces() below
            # can restart wlm-api/workloads/scheduler/cron via restart_map.
            # Otherwise those services come back up on the just-installed
            # package against a schema that hasn't been migrated yet
            # (TVAULT-7522).
            charm_class.db_sync()
        charm_class.render_with_interfaces(args)
        charm_class.assess_status()

    render_wlm_and_dms_configs(*args)
    set_flag("config.rendered")


def render_wlm_and_dms_configs(*args):
    """Render triliovault-wlm.conf and the DMS server/client configs.

    Extracted from render_config() so it can also be called directly from
    the update-trilio action (charms.reactive actions never go through the
    reactive hook-dispatch loop, so this handler would otherwise not run
    again until some later hook fires — TVAULT-7521).
    """
    haproxy_port = 8780
    api_port = determine_api_port(haproxy_port, singlenode_mode=True)

    # Load configurations
    charm_config = config()

    # Retrieve database connection details from the shared-db interface
    shared_db = reactive.RelationBase.from_state('shared-db.available')

    # Retrieve AMQP connection details from the amqp interface
    amqp = reactive.RelationBase.from_state('amqp.available')

    db_user = shared_db.username()
    db_password = shared_db.password()
    db_name = shared_db.database()
    db_host = '127.0.0.1'
    db_port = 3306

    sql_connection = f"mysql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"

    amqp_username = amqp.username()
    amqp_password = amqp.password()
    amqp_host = amqp.private_address()
    amqp_port = amqp.ssl_port() or 5672
    amqp_vhost = amqp.vhost()

    transport_url = f"rabbit://{amqp_username}:{amqp_password}@{amqp_host}:{amqp_port}/{amqp_vhost}"
    my_host_ip = hookenv.unit_private_ip()

    identity_service = {}

    relation_ids = hookenv.relation_ids('identity-service')

    if relation_ids:
        relation_id = relation_ids[0]
        related_units = hookenv.related_units(relation_id)

        for unit in related_units:
            unit_data = hookenv.relation_get(unit=unit, rid=relation_id)
            if unit_data:
                identity_service.update(unit_data)
                hookenv.log(f"Using identity service data from unit {unit}: {unit_data}")
                break
    else:
        hookenv.log("No relation ID found for identity-service", level=hookenv.ERROR)
        return

    if not identity_service:
        hookenv.log("Failed to retrieve valid identity service data", level=hookenv.ERROR)
        return

    ep_changed = json.loads(identity_service.get('ep_changed', '{}'))

    identity_service['cinder_url'] = ep_changed.get('cinderv3', {}).get('internal')
    identity_service['nova_url'] = ep_changed.get('nova', {}).get('internal')
    identity_service['glance_url'] = ep_changed.get('glance', {}).get('internal')
    identity_service['neutron_url'] = ep_changed.get('neutron', {}).get('internal')

    # Build Keystone internal auth URL for DMS
    keystone_auth_url = "{}://{}:{}/v3".format(
        identity_service.get('auth_protocol', 'http'),
        identity_service.get('auth_host', ''),
        identity_service.get('auth_port', '5000'),
    )

    hookenv.log(f"identity_service object: {identity_service}")

    wlm_context = {
        'options': {
            'workers': charm_config.get('workers', 2),
            'max_wait_for_upload': charm_config.get('max-wait-for-upload', 300),
            'service_listen_info': {'workloadmgr_api': {'port': api_port}},
            'bind_port': api_port,
            'verbose': charm_config.get('verbose', False),
            'debug': charm_config.get('debug', False),
            'trustee_role': charm_config.get('trustee-role', 'member'),
            'region': charm_config.get('region', 'RegionOne'),
            'progress_tracking_update_interval': charm_config.get('progress-tracking-update-interval', 1200),
            'client_retry_limit': 5,
            'misfire_grace_time': 10,
            'process_timeout': 300,
            'memcache_url': 'memcache-url',
            'use_memcache': False,
            'sql_connection': sql_connection,
            'transport_url': transport_url,
            'vhost': amqp_vhost,
            'triliovault_hostnames': my_host_ip,
        },
        'backup_targets': [],
        'amqp': amqp,
        'shared_db': shared_db,
        'identity_service': identity_service,
        'cluster': {'internal_addresses': ['127.0.0.1']},
    }

    root_uid = pwd.getpwnam('root').pw_uid
    nova_uid = pwd.getpwnam('nova').pw_uid
    nova_gid = grp.getgrnam('nova').gr_gid

    # Pre-create WLM log files with nova ownership so services can write to them.
    log_dir = '/var/log/triliovault'
    os.makedirs(log_dir, exist_ok=True)
    os.chown(log_dir, nova_uid, nova_gid)
    for log_file_name in [
        'triliovault-wlm-api.log',
        'triliovault-wlm-cron.log',
        'triliovault-wlm-scheduler.log',
        'triliovault-wlm-workloads.log',
    ]:
        log_file = os.path.join(log_dir, log_file_name)
        if not os.path.exists(log_file):
            open(log_file, 'w').close()
        os.chown(log_file, nova_uid, nova_gid)

    wlm_conf_dir = "/etc/triliovault-wlm"
    wlm_conf_file_path = '/etc/triliovault-wlm/triliovault-wlm.conf'
    render(
        source='triliovault-wlm.conf',
        target=wlm_conf_file_path,
        context=wlm_context
    )
    os.chmod(wlm_conf_file_path, 0o640)
    os.chown(wlm_conf_file_path, root_uid, nova_gid)
    os.chmod(wlm_conf_dir, 0o755)
    os.chown(wlm_conf_dir, root_uid, nova_gid)

    # Render DMS server config (WLM control-plane nodes also run trilio-dms-server server)
    dms_conf_dir = '/etc/triliovault-dms'
    os.makedirs(dms_conf_dir, exist_ok=True)
    os.chown(dms_conf_dir, root_uid, nova_gid)

    # Derive barbican CA bundle from identity-service relation ca_cert (canonical way)
    ca_cert = identity_service.get('ca_cert', '')
    if ca_cert:
        host.install_ca_cert(ca_cert, 'keystone_juju_ca_cert')
        barbican_ca_bundle = '/usr/local/share/ca-certificates/keystone_juju_ca_cert.crt'
    else:
        barbican_ca_bundle = ''

    dms_server_context = {
        'rabbitmq_url': transport_url,
        'node_id': socket.getfqdn(),
        'auth_url': keystone_auth_url,
        'barbican_ssl_verify': 'True' if barbican_ca_bundle else 'False',
        'barbican_ca_bundle': barbican_ca_bundle,
    }
    dms_server_conf_path = os.path.join(dms_conf_dir, 'server.conf')
    render(
        source='etc_triliovault-dms_server.conf',
        target=dms_server_conf_path,
        context=dms_server_context,
    )
    os.chmod(dms_server_conf_path, 0o640)
    os.chown(dms_server_conf_path, root_uid, nova_gid)

    # Render DMS client config for WLM
    dms_client_context = {
        'rabbitmq_url': transport_url,
        'db_url': f"mysql+pymysql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}",
        'node_id': socket.getfqdn(),
    }
    dms_client_conf_path = os.path.join(dms_conf_dir, 'client.conf')
    render(
        source='etc_triliovault-dms_client.conf',
        target=dms_client_conf_path,
        context=dms_client_context,
    )
    os.chmod(dms_client_conf_path, 0o640)
    os.chown(dms_client_conf_path, root_uid, nova_gid)

    # Render s3vaultfuse global config for DMS server
    dms_s3vaultfuse_conf_path = os.path.join(dms_conf_dir, 's3vaultfuse-global.conf')
    render(
        source='etc_triliovault-dms_s3vaultfuse-global.conf',
        target=dms_s3vaultfuse_conf_path,
        context={},
    )
    os.chmod(dms_s3vaultfuse_conf_path, 0o644)
    os.chown(dms_s3vaultfuse_conf_path, root_uid, nova_gid)

    # Enable and (re)start DMS server service
    host.service('enable', 'trilio-dms-server')
    if host.service_running('trilio-dms-server'):
        host.service('restart', 'trilio-dms-server')
    else:
        host.service('start', 'trilio-dms-server')

    set_flag("config.rendered")


@reactive.when("config.rendered")
def init_db():
    with charm.provide_charm_instance() as charm_class:
        charm_class.db_sync()


@reactive.when("ha.connected")
def cluster_connected(hacluster):
    """Configure HA resources in corosync"""
    with charm.provide_charm_instance() as charm_class:
        charm_class.configure_ha_resources(hacluster)
        charm_class.assess_status()


@reactive.when("identity-service.connected")
def register_endpoints_and_request_notification(identity_service):
    """Register endpoints and request notification."""
    with charm.provide_charm_instance() as instance:
        identity_service.request_notification(instance.required_services)
        identity_service.register_endpoints(
            instance.service_type,
            instance.region,
            instance.public_url,
            instance.internal_url,
            instance.admin_url,
            requested_roles=[instance.options.trustee_role])
        instance.assess_status()


@reactive.when_any("config.changed.triliovault-pkg-source",
                   "config.changed.openstack-origin")
def install_source_changed():
    """Trigger re-install of charm if source configuration options change"""
    reactive.clear_flag("charm.installed")
    reactive.set_flag("upgrade.triliovault")


@hook('config-changed')
def config_changed():
    is_vmware_migration_enabled = config('is-vmware-migration-enabled')
    is_vcenter_ssl_not_enabled = config('vcenter-nossl')

    if is_vmware_migration_enabled and not is_vcenter_ssl_not_enabled:
        set_flag('charm.vcenter-ssl-copy')
    else:
        clear_flag('charm.vcenter-ssl-copy')


@when('charm.vcenter-ssl-copy')
def copy_vcenter_ssl_cert():
    try:
        vcenter_ssl_cert = config('vcenter-ssl-cert')
        dest_path = '/etc/triliovault-wlm/vcenter-cert.pem'
        status_set('maintenance', f'Copying SSL certificate to {dest_path}')
        with open(dest_path, "w") as vcenter_file:
            vcenter_file.write(vcenter_ssl_cert)
        status_set('active', 'SSL certificate copied successfully')
        clear_flag('charm.vcenter-ssl-copy')
    except Exception as e:
        status_set('blocked', f'Failed to copy SSL certificate: {e}')
