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
import os
import pwd
import grp
from subprocess import check_call, CalledProcessError
from charmhelpers.core.host import restart_on_change
import multiline
import subprocess
import charms_openstack.charm as charm
import charms.reactive as reactive
from charmhelpers.core.templating import render
from charmhelpers.core.hookenv import config, log
from charmhelpers.core import hookenv
import json
from charmhelpers.core import host
from charms.reactive import when, set_state
# This charm's library contains all of the handler code for this charm
import charm.openstack.trilio_wlm as trilio_wlm  # noqa
from charm.openstack.trilio_wlm import TrilioWLMBaseCharm
import apt
import apt.progress.text
import shutil
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
import base64

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
    set_state('maintenance', 'Running Trilio Install Upgrade Packages')
    dpkg_opts = [
        '--option', 'Dpkg::Options::=--force-confnew',
        '--option', 'Dpkg::Options::=--force-confdef',
    ]
    
    # Initialize the apt cache
    cache = apt.Cache()
    cache.update()
    cache.open()

    for package_name in packages:
        pkg = cache.get(package_name)

        if pkg is None:
            print(f"Package {package_name} not found in the cache.")
            continue

        if pkg.is_installed and pkg.is_upgradable:
            print(f"Upgrading package: {package_name}")
            # Upgrade package using apt-get with dpkg options, without prompting for input
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
            # Install package using apt-get with dpkg options, without prompting for input
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


charm_config = config()
backup_targets = multiline.loads(charm_config.get('trilio-backup-targets', '[]'), multiline=True)

charm_instance = TrilioWLMBaseCharm()
services_to_restart = charm_instance.services


wlm_conf_file_path = '/etc/triliovault-wlm/triliovault-wlm.conf'
object_store_conf_dir = "/etc/triliovault-object-store"

# Dynamically collect paths for all target-specific configurations
config_paths = [wlm_conf_file_path] + [
    f"{object_store_conf_dir}/triliovault-object-store-{target['backup-target-name']}.conf"
    for target in backup_targets
]




@reactive.when_not('is-update-status-hook')
@reactive.when("shared-db.available")
@reactive.when("identity-service.available")
@reactive.when("amqp.available")
@restart_on_change({path: services_to_restart for path in config_paths})
def render_config(*args):
    """Render the configuration for the charm when all the interfaces are available."""

    haproxy_port = 8780
    api_port = determine_api_port(haproxy_port, singlenode_mode=True)
    with charm.provide_charm_instance() as charm_class:
        trilio_charm_instance = trilio_wlm.TrilioWLMBaseCharm()
        packages_to_install = trilio_charm_instance.base_packages
        hookenv.log(f"Trilio Wlm Charm Packages: {packages_to_install}")
        # Check if 'triliovault-pkg-source' configuration has changed and install/upgrade packages if needed
        current_pkg_source = hookenv.config('triliovault-pkg-source')
        is_trilio_pkg_source_changed = reactive.helpers.data_changed('triliovault-pkg-source', current_pkg_source)
        if is_trilio_pkg_source_changed or not reactive.is_state('triliovault-packages.installed'):
            run_trilio_install_upgrade_packages(packages_to_install)
            reactive.set_state('triliovault-packages.installed')
        charm_class.render_with_interfaces(args)
        charm_class.assess_status()

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
    db_port = 3306  # Default MySQL port

    # Construct the SQL connection string
    sql_connection = f"mysql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"

    # Construct the SQL connection string
    # Log the sql_connection string for debugging

    amqp_username = amqp.username()
    amqp_password = amqp.password()
    amqp_host = amqp.private_address()
    amqp_port = amqp.ssl_port() or 5672  # Or use a non-SSL port if necessary
    amqp_vhost = amqp.vhost()

    # Construct the transport URL
    transport_url = f"rabbit://{amqp_username}:{amqp_password}@{amqp_host}:{amqp_port}/{amqp_vhost}"
    my_host_ip = hookenv.unit_private_ip()


    # Retrieve identity service (Keystone) details
#    identity_service = reactive.RelationBase.from_state('identity-service.available')


    identity_service = {}

    # Get the relation ID for the identity service relation
    relation_ids = hookenv.relation_ids('identity-service')

    if relation_ids:
        relation_id = relation_ids[0]  # Assuming there's only one relation for simplicity

        # Retrieve data from the first valid related unit
        related_units = hookenv.related_units(relation_id)

        for unit in related_units:
            unit_data = hookenv.relation_get(unit=unit, rid=relation_id)
            if unit_data:
                identity_service.update(unit_data)  # Update the identity_service dict with this unit's data
                hookenv.log(f"Using identity service data from unit {unit}: {unit_data}")
                break  # Exit loop after finding the first valid unit's data
    else:
        hookenv.log("No relation ID found for identity-service", level=hookenv.ERROR)
        return

    if not identity_service:
        hookenv.log("Failed to retrieve valid identity service data", level=hookenv.ERROR)
        return

    ep_changed = json.loads(identity_service.get('ep_changed', '{}'))

    # Extract and map the internal URLs
    identity_service['cinder_url'] = ep_changed.get('cinderv3', {}).get('internal')
    identity_service['nova_url'] = ep_changed.get('nova', {}).get('internal')
    identity_service['glance_url'] = ep_changed.get('glance', {}).get('internal')
    identity_service['neutron_url'] = ep_changed.get('neutron', {}).get('internal')

    hookenv.log(f"identity_service object: {identity_service}")
# Parse 'trilio-backup-targets' from JSON string to Python list
    backup_targets = multiline.loads(charm_config.get('trilio-backup-targets', '[]'), multiline=True)

    root_uid = pwd.getpwnam('root').pw_uid
    nova_gid = grp.getgrnam('nova').gr_gid
    for target in backup_targets:
        if target.get('backup-target-type') not in ['s3', 'nfs']:
            continue

        # Initialize mount point and storage export variables
        vault_storage_nfs_export = ""


        if target['backup-target-type'] == 's3':
            endpoint_url = target['s3-endpoint-url'].rstrip('/')  # Trim trailing slash if present
            if target['s3-type'] == 'amazon_s3':
                vault_storage_nfs_export = target['s3-bucket']
            else:
                s3_domain_name = endpoint_url.replace('https://', '').replace('http://', '')
                bucket_name = target['s3-bucket']
                ceph_s3_str = f"{s3_domain_name}/{bucket_name}"
                vault_storage_nfs_export = ceph_s3_str
        target['vault-storage-nfs-export'] = vault_storage_nfs_export


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
        'backup_targets': backup_targets,
        'amqp': amqp,
        'shared_db': shared_db,
        'identity_service': identity_service,
        'cluster': {'internal_addresses': ['127.0.0.1']},  # Example cluster data
    }
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


    # Iterate over each backup target and render configuration
    for target in backup_targets:
        if target.get('backup-target-type') not in ['s3', 'nfs']:
            continue

        # Initialize mount point and storage export variables
        backup_target_mount_point = ""
        vault_storage_nfs_export = ""

        if target['backup-target-type'] == 's3':
            endpoint_url = target['s3-endpoint-url'].rstrip('/')  # Trim trailing slash if present
            if target['s3-type'] == 'amazon_s3':
                backup_target_mount_point = base64.b64encode(target['s3-bucket'].encode()).decode()
                vault_storage_nfs_export = target['s3-bucket']
            else:
                s3_domain_name = endpoint_url.replace('https://', '').replace('http://', '')
                bucket_name = target['s3-bucket']
                ceph_s3_str = f"{s3_domain_name}/{bucket_name}"
                backup_target_mount_point = base64.b64encode(ceph_s3_str.encode()).decode()
                vault_storage_nfs_export = ceph_s3_str



            object_store_context = {
                'options': {
                    'backup_target_type': target.get('backup-target-type'),
                    'backup_target_name': target.get('backup-target-name'),
                    'backup_target_mount_point': backup_target_mount_point,
                    'vault_storage_nfs_export': vault_storage_nfs_export,
                    'is_default': target.get('is-default'),
                    'workers': charm_config.get('workers', 2),
                    'verbose': charm_config.get('verbose', False),
                    'debug': charm_config.get('debug', False),
                }
            }
            object_store_context['options'].update({
                's3_type': target.get('s3-type'),
                's3_access_key': target.get('s3-access-key'),
                's3_secret_key': target.get('s3-secret-key'),
                's3_region_name': target.get('s3-region-name'),
                's3_bucket': target.get('s3-bucket'),
                's3_endpoint_url': target.get('s3-endpoint-url', ''),
                's3_signature_version': target.get('s3-signature-version', 'default'),
                's3_auth_version': target.get('s3-auth-version', 'DEFAULT'),
                's3_ssl_enabled': target.get('s3-ssl-enabled', True),
                's3_ssl_verify': target.get('s3-ssl-verify', True),
                's3_self_signed_cert': target.get('s3-self-signed-cert', False),
                's3_ssl_ca_cert': target.get('s3-ssl-ca_cert', ''),
                's3_bucket_object_lock_enabled': target.get('s3-bucket-object-lock-enabled', False)
            })


            if target.get('s3-self-signed-cert'):
                s3_cert_file_path = f'/etc/triliovault-object-store/s3-cert-{target["backup-target-name"]}.pem'
                with open(s3_cert_file_path, 'w') as cert_file:
                    cert_file.write(target['s3-ssl-ca_cert'])
                os.chmod(s3_cert_file_path, 0o640)
                os.chown(s3_cert_file_path, root_uid, nova_gid)
            # Render the configuration file with the context
            object_store_conf_file_path = f'/etc/triliovault-object-store/triliovault-object-store-{target["backup-target-name"]}.conf'
            render(
                source='triliovault-object-store.conf',
                target=object_store_conf_file_path,
                context=object_store_context
            )
            os.chmod(object_store_conf_file_path, 0o640)
            os.chown(object_store_conf_file_path, root_uid, nova_gid)
            object_store_conf_dir = "/etc/triliovault-object-store"
            os.chmod(object_store_conf_dir, 0o755)
            os.chown(object_store_conf_dir, root_uid, nova_gid)
            render_systemd_service(target)


    # Disable and stop the default tvault-object-store service to prevent it
    # from spamming syslog with errors due to empty configuration variables.
    # In T4O 6.x, the python3-s3-fuse-plugin package is always installed and
    # creates this default service, but per-bucket services
    # (e.g. tvault-object-store-<name>) are used instead.
    host.service('disable', 'tvault-object-store.service')
    host.service('stop', 'tvault-object-store.service')

    # Update the charm status and other necessary actions
    set_state("config.rendered")


@when('config.changed.trilio-backup-targets')
def handle_backup_targets_change():
    cfg = config()
    targets = cfg.get('trilio-backup-targets')

    # Parse the JSON string from the configuration
    backup_targets = multiline.loads(targets, multiline=True)

    # Render systemd service for each backup target
    for target in backup_targets:
        if target.get('backup-target-type') == 's3':
            render_systemd_service(target)

    # Set a flag if needed to indicate that services have been rendered
    set_flag('trilio-backup-targets.rendered')


def render_systemd_service(target):
    template_file = 'tvault-object-store.service.j2'
    service_name = f"tvault-object-store-{target['backup-target-name']}.service"
    output_file = f"/etc/systemd/system/{service_name}"

    context = {
        'backup_target_name': target['backup-target-name']
        # Add other necessary context variables here
    }

    def daemon_reload_and_restart(service):
        host.service_reload('systemd')
        if host.service_running(service):
            host.service('restart', service)

    host.service('enable', service_name)
    with restart_on_change({output_file: [service_name]}, restart_functions={service_name: daemon_reload_and_restart}):
        render(template_file, output_file, context)


@when('config.rendered')
def mount_nfs_shares():
    charm_config = config()
    backup_targets = multiline.loads(charm_config.get('trilio-backup-targets', '[]'), multiline=True)
    for target in backup_targets:
        if target.get('backup-target-type') == 'nfs':
            nfs_share = target.get('nfs-shares')
            nfs_options = target.get('nfs-options', 'defaults')
            if nfs_share:
                nfs_dir = nfs_share.split(':')[1]
                base64_mount_point = base64.b64encode(nfs_dir.encode('utf-8')).decode('utf-8')
                mount_point = f"/var/triliovault-mounts/{base64_mount_point}"
                os.makedirs(mount_point, exist_ok=True)
                mount_cmd = ['sudo', '/usr/bin/workloadmgr-rootwrap', '/etc/triliovault-wlm/rootwrap.conf', 'mount', '-t', 'nfs', nfs_share, mount_point, '-o', nfs_options]
                try:
                    check_call(mount_cmd)
                    hookenv.log(f"Mounted {nfs_share} at {mount_point}")
                except CalledProcessError as e:
                    hookenv.log(f"Failed to mount {nfs_share} at {mount_point}: {e}", level=hookenv.ERROR)
            else:
                hookenv.log(f"No NFS share specified for target: {target.get('backup-target-name', 'unknown')}", level=hookenv.WARNING)
    reactive.set_state('nfs.mounts.configured')


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
    """Register endpoints and request notification.

    Note: In order to pass the requested role(s), we must override the default
    openstack-api layer setup_endpoint_connection version of this handler.
    """
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
    # Get the value of the is-vmware-migration-enabled configuration parameter
    is_vmware_migration_enabled = config('is-vmware-migration-enabled')
    is_vcenter_ssl_not_enabled = config('vcenter-nossl')

    # Check if the is-vmware-migration-enabled parameter is set to True
    if is_vmware_migration_enabled and not is_vcenter_ssl_not_enabled:
        set_flag('charm.vcenter-ssl-copy')
    else:
        clear_flag('charm.vcenter-ssl-copy')


@when('charm.vcenter-ssl-copy')
def copy_vcenter_ssl_cert():
    try:
        # Fetch the SSL certificate resource
        vcenter_ssl_cert = config('vcenter-ssl-cert')
        dest_path = '/etc/triliovault-wlm/vcenter-cert.pem'
        status_set('maintenance', f'Copying SSL certificate to {dest_path}')
        with open(dest_path, "w") as vcenter_file:
            vcenter_file.write(vcenter_ssl_cert)
        status_set('active', 'SSL certificate copied successfully')
        clear_flag('charm.vcenter-ssl-copy')
    except Exception as e:
        status_set('blocked', f'Failed to copy SSL certificate: {e}')
