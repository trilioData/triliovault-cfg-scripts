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
import multiline
import subprocess
from charmhelpers.core.templating import render
from charmhelpers.core.hookenv import config, log
from charmhelpers.core import hookenv
import json
from charmhelpers.core import host
from charmhelpers.core.host import restart_on_change
from charms.reactive import when, set_state
import apt
import apt.progress.text
import base64

import charms_openstack.charm as charm
import charms.reactive as reactive
import charmhelpers.core.kernel as ch_kernel
import charmhelpers.core.host as ch_host
import charmhelpers.core.hookenv as ch_hookenv

# This charm's library contains all of the handler code associated with
# trilio_dm
import charm.openstack.trilio_dm as trilio_dm  # noqa

import os
import shutil
import tarfile
import subprocess
from charmhelpers.core.hookenv import (
    config,
    resource_get,
    status_set,
)
from charmhelpers.core.host import chdir
from charms.reactive import (
    when,
    hook,
    set_flag,
    clear_flag,
)

charm.use_defaults(
    "charm.installed", "config.changed", "update-status",
    "shared-db.connected",
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



@reactive.when_not('is-update-status-hook')
@reactive.when("shared-db.available")
@reactive.when("amqp.available")
def render_config(*args):
    """Render the configuration for the charm when all the interfaces are available."""
    ceph = reactive.endpoint_from_flag("ceph.available")
    if ceph:
        args = (ceph,) + args
    with charm.provide_charm_instance() as charm_class:
        template_list = ["/etc/triliovault-datamover/triliovault-datamover.conf","/etc/triliovault-datamover/datamover_logging.conf","/etc/triliovault-object-store/object_store_logging.conf"]
        trilio_charm_instance = trilio_dm.TrilioDataMoverBaseCharm()
        packages_to_install = trilio_charm_instance.base_packages
        hookenv.log(f"Trilio Datamover Charm Packages: {packages_to_install}")

        # Check if 'triliovault-pkg-source' configuration has changed and install/upgrade packages if needed
        current_pkg_source = hookenv.config('triliovault-pkg-source')
        is_trilio_pkg_source_changed = reactive.helpers.data_changed('triliovault-pkg-source', current_pkg_source)
        if is_trilio_pkg_source_changed or not reactive.is_state('triliovault-packages.installed'):
            run_trilio_install_upgrade_packages(packages_to_install)
            reactive.set_state('triliovault-packages.installed')

        charm_class.render_with_interfaces(args, configs=template_list)

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

    # dm_context = {
    #     'options': {
    #         'verbose': charm_config.get('verbose', False),
    #         'debug': charm_config.get('debug', False),
    #         'sql_connection': sql_connection,
    #         'transport_url': transport_url,
    #         'vhost': amqp_vhost,
    #     },
    #     'backup_targets': backup_targets,
    #     'amqp': amqp,
    #     'shared_db': shared_db,
    #     'cluster': {'internal_addresses': ['127.0.0.1']},  # Example cluster data
    # }
    # wlm_conf_dir = "/etc/triliovault-datamover"
    # wlm_conf_file_path = '/etc/triliovault-datamover/triliovault-datamover.conf'
    # render(
    #     source='triliovault-datamover.conf',
    #     target=wlm_conf_file_path,
    #     context=dm_context
    # )
    # os.chmod(wlm_conf_file_path, 0o640)
    # os.chown(wlm_conf_file_path, root_uid, nova_gid)
    # os.chmod(wlm_conf_dir, 0o755)
    # os.chown(wlm_conf_dir, root_uid, nova_gid)


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


    # Disable and stop the default tvault-object-store service when per-target
    # services are in use, to prevent it spamming syslog with errors from the
    # empty default configuration file.
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
                mount_cmd = ['sudo', 'nova-rootwrap', '/etc/nova/rootwrap.conf', 'mount', '-t', 'nfs', nfs_share, mount_point, '-o', nfs_options]
                try:
                    check_call(mount_cmd)
                    hookenv.log(f"Mounted {nfs_share} at {mount_point}")
                except CalledProcessError as e:
                    hookenv.log(f"Failed to mount {nfs_share} at {mount_point}: {e}", level=hookenv.ERROR)
            else:
                hookenv.log(f"No NFS share specified for target: {target.get('backup-target-name', 'unknown')}", level=hookenv.WARNING)
    reactive.set_state('nfs.mounts.configured')


@reactive.when_not('is-update-status-hook')
@reactive.when('charm.installed')
def setup_kernel_modules():
    module = 'nbd'
    if ch_host.is_container():
        ch_hookenv.log(
            "Cannot load modules inside of a container",
            level=ch_hookenv.WARNING)
    else:
        try:
            ch_kernel.modprobe(module)
        except Exception:
            ch_hookenv.log(
                "Failed to load kernel module '%s'" % module,
                level=ch_hookenv.WARNING)


@reactive.when('shared-db.connected')
def default_setup_database(database):
    """Handle the default database connection setup

    This requires that the charm implements get_database_setup() to provide
    a list of dictionaries;
    [{'database': ..., 'username': ..., 'hostname': ..., 'prefix': ...}]

    The prefix can be missing: it defaults to None.
    """
    with charm.provide_charm_instance() as instance:
        for db in instance.get_database_setup():
            database.configure(**db)
        instance.assess_status()


# NOTE(jamespage): default handler is in api layer which is to much
@reactive.when("amqp.connected")
def default_amqp_connection(amqp):
    """Handle the default amqp connection.

    This requires that the charm implements get_amqp_credentials() to
    provide a tuple of the (user, vhost) for the amqp server
    """
    with charm.provide_charm_instance() as charm_instance:
        user, vhost = charm_instance.get_amqp_credentials()
        amqp.request_access(username=user, vhost=vhost)
        charm_instance.assess_status()


@reactive.when("config.changed.triliovault-pkg-source")
def install_source_changed():
    """Trigger re-install of charm if source configuration options change"""
    reactive.clear_flag("charm.installed")
    reactive.set_flag("upgrade.triliovault")


@reactive.when_not("ceph.access.req.sent")
@reactive.when("ceph.connected")
def ceph_connected(ceph):
    with charm.provide_charm_instance() as charm_instance:
        charm_instance.request_access_to_groups(ceph)
        reactive.set_flag("ceph.access.req.sent")


@reactive.when("ceph.available")
def configure_ceph(ceph):
    with charm.provide_charm_instance() as charm_instance:
        charm_instance.configure_ceph_keyring(ceph.key)
        charm_instance.assess_status()

@hook('config-changed')
def config_changed():
    # Get the value of the is-vmware-migration-enabled configuration parameter
    is_vmware_migration_enabled = config('is-vmware-migration-enabled')

    # Check if the is-vmware-migration-enabled parameter is set to True
    if is_vmware_migration_enabled:
        set_flag('charm.vmware-vddk-setup')
    else:
        clear_flag('charm.vmware-vddk-setup')


@when('charm.vmware-vddk-setup')
def setup_vmware_vddk():
    try:
        status_set('maintenance', 'Setting up VMware VDDK...')

        # Fetch the resource and copy it to the desired location
        vddk_bundle_path = resource_get('vddk_bundle')
        dest_path = '/opt/vddk.tar.gz'
        shutil.copy(vddk_bundle_path, dest_path)

        # Create the directory and extract the tarball
        os.makedirs('/opt/vmware-vix-disklib-distrib', exist_ok=True)
        with tarfile.open(dest_path, 'r:gz') as tar:
            tar.extractall(path='/opt/vmware-vix-disklib-distrib', members=[member for member in tar.getmembers() if member.name.startswith('vmware-vix-disklib-distrib/')])

        # Change ownership
        subprocess.run(['chown', '-R', 'nova:nova', '/opt/vmware-vix-disklib-distrib'], check=True)

        # Download and setup nbdkit
        with chdir('/opt'):
            subprocess.run(['wget', 'https://download.libguestfs.org/nbdkit/1.30-stable/nbdkit-1.30.10.tar.gz'], check=True)
            with tarfile.open('nbdkit-1.30.10.tar.gz', 'r:gz') as tar:
                tar.extractall()

            with chdir('nbdkit-1.30.10'):
                subprocess.run(['./configure'], check=True)
                subprocess.run(['make'], check=True)
                subprocess.run(['make', 'check-vddk', f'vddkdir=/opt/vmware-vix-disklib-distrib'], check=True)
                subprocess.run(['make', 'install'], check=True)

        status_set('active', 'VMware VDDK setup completed successfully')
        clear_flag('charm.vmware-vddk-setup')
    except Exception as e:
        status_set('blocked', f'Failed to set up VMware VDDK: {e}')
