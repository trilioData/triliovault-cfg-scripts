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
import shutil
import tarfile
import subprocess
from charmhelpers.core.templating import render
from charmhelpers.core.hookenv import config, log
from charmhelpers.core import hookenv
from charmhelpers.core import host
from charms.reactive import when, set_state, hook, set_flag, clear_flag

import charms_openstack.charm as charm
import charms.reactive as reactive
import charmhelpers.core.kernel as ch_kernel
import charmhelpers.core.host as ch_host
import charmhelpers.core.hookenv as ch_hookenv
from charmhelpers.core.hookenv import (
    config,
    resource_get,
    status_set,
)

import apt

# This charm's library contains all of the handler code associated with
# trilio_dm
import charm.openstack.trilio_dm as trilio_dm  # noqa

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
@reactive.when("amqp.available")
def render_config(*args):
    """Render the configuration for the charm when all the interfaces are available."""
    ceph = reactive.endpoint_from_flag("ceph.available")
    if ceph:
        args = (ceph,) + args
    with charm.provide_charm_instance() as charm_class:
        template_list = [
            "/etc/triliovault-datamover/triliovault-datamover.conf",
            "/etc/triliovault-datamover/datamover_logging.conf",
            "/etc/triliovault-object-store/object_store_logging.conf",
        ]
        trilio_charm_instance = trilio_dm.TrilioDataMoverBaseCharm()
        packages_to_install = trilio_charm_instance.base_packages
        hookenv.log(f"Trilio Datamover Charm Packages: {packages_to_install}")

        current_pkg_source = hookenv.config('triliovault-pkg-source')
        is_trilio_pkg_source_changed = reactive.helpers.data_changed(
            'triliovault-pkg-source', current_pkg_source)
        if is_trilio_pkg_source_changed or not reactive.is_state('triliovault-packages.installed'):
            run_trilio_install_upgrade_packages(packages_to_install)
            trilio_list = '/etc/apt/sources.list.d/trilio.list'
            if os.path.exists(trilio_list):
                try:
                    os.remove(trilio_list)
                    hookenv.log("Cleaned up trilio apt source list.")
                except OSError as e:
                    hookenv.log(f"Failed to remove trilio apt source: {e}", level=hookenv.WARNING)
            reactive.set_state('triliovault-packages.installed')

        charm_class.render_with_interfaces(args, configs=template_list)

    # Retrieve AMQP connection details from the amqp interface
    amqp = reactive.RelationBase.from_state('amqp.available')
    amqp_username = amqp.username()
    amqp_password = amqp.password()
    amqp_host = amqp.private_address()
    amqp_port = amqp.ssl_port() or 5672
    amqp_vhost = amqp.vhost()
    transport_url = f"rabbit://{amqp_username}:{amqp_password}@{amqp_host}:{amqp_port}/{amqp_vhost}"

    charm_config = config()
    keystone_auth_url = charm_config.get('keystone-auth-url', '')

    root_uid = pwd.getpwnam('root').pw_uid
    nova_gid = grp.getgrnam('nova').gr_gid

    # Render DMS server config
    dms_conf_dir = '/etc/triliovault-dms'
    os.makedirs(dms_conf_dir, exist_ok=True)
    os.makedirs(os.path.join(dms_conf_dir, 'client.conf.d'), exist_ok=True)
    os.chown(dms_conf_dir, root_uid, nova_gid)

    dms_server_context = {
        'rabbitmq_url': transport_url,
        'node_id': hookenv.unit_private_ip(),
        'auth_url': keystone_auth_url,
        'barbican_ssl_verify': 'False',
    }
    dms_server_conf_path = os.path.join(dms_conf_dir, 'dms-server.conf')
    render(
        source='triliovault-dms-server.conf',
        target=dms_server_conf_path,
        context=dms_server_context,
    )
    os.chmod(dms_server_conf_path, 0o640)
    os.chown(dms_server_conf_path, root_uid, nova_gid)

    # Enable and (re)start DMS server service
    host.service('enable', 'trilio-dms')
    if host.service_running('trilio-dms'):
        host.service('restart', 'trilio-dms')
    else:
        host.service('start', 'trilio-dms')

    set_state("config.rendered")


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
    """Handle the default database connection setup"""
    with charm.provide_charm_instance() as instance:
        for db in instance.get_database_setup():
            database.configure(**db)
        instance.assess_status()


@reactive.when("amqp.connected")
def default_amqp_connection(amqp):
    """Handle the default amqp connection."""
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
    is_vmware_migration_enabled = config('is-vmware-migration-enabled')
    if is_vmware_migration_enabled:
        set_flag('charm.vmware-vddk-setup')
    else:
        clear_flag('charm.vmware-vddk-setup')


@when('charm.vmware-vddk-setup')
def setup_vmware_vddk():
    try:
        status_set('maintenance', 'Setting up VMware VDDK...')

        vddk_bundle_path = resource_get('vddk_bundle')
        dest_path = '/opt/vddk.tar.gz'
        shutil.copy(vddk_bundle_path, dest_path)

        os.makedirs('/opt/vmware-vix-disklib-distrib', exist_ok=True)
        with tarfile.open(dest_path, 'r:gz') as tar:
            tar.extractall(path='/opt/vmware-vix-disklib-distrib', members=[member for member in tar.getmembers() if member.name.startswith('vmware-vix-disklib-distrib/')])

        subprocess.run(['chown', '-R', 'nova:nova', '/opt/vmware-vix-disklib-distrib'], check=True)

        from charmhelpers.core.host import chdir
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
