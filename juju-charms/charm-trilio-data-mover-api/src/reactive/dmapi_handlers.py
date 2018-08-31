import charms.reactive as reactive
import charmhelpers.core.hookenv as hookenv
import os
import netaddr

# This charm's library contains all of the handler code associated with
# dmapi
import charm.openstack.dmapi as dmapi
from charmhelpers.core.hookenv import (
    config,
    log,
)

from charmhelpers.fetch import (
    add_source,
    apt_install,
    apt_update,
)

from charmhelpers.core.host import (
    service_restart,
)

# Minimal inferfaces required for operation
MINIMAL_INTERFACES = [
    'shared-db.available',
    'identity-service.available',
    'amqp.available',
]


def validate_ip(ip):
    """
    Validate triliovault_ip provided by the user
    triliovault_ip should not be blank
    triliovault_ip should have a valid IP address and reachable
    """
    if ip.strip():
        # Not blank
        if netaddr.valid_ipv4(ip):
            # Valid IP address, check if it's reachable
            if os.system("ping -c 1 " + ip):
                return False
            return True
        else:
            # Invalid IP address
            return False
    return False


# use a synthetic state to ensure that it get it to be installed independent of
# the install hook.
@reactive.when_not('charm.installed')
def install_packages():
    # Add TrilioVault repository to install required package
    # and add queens repo to install nova libraries
    if not validate_ip(config('triliovault-ip')):
        log("Invalid IP address !")
        return
    add_source('deb http://{}:8085/deb-repo /'.format(
                config('triliovault-ip')))
    os.system('sudo add-apt-repository cloud-archive:queens')
    apt_update()
    dmapi.install()
    apt_install(['dmapi'], options=['--allow-unauthenticated'], fatal=True)
    # Placing the service file
    os.system('sudo cp files/trilio/trilio-data-mover-api.service '
              '/etc/systemd/system/')
    os.system('sudo systemctl enable trilio-data-mover-api')
    service_restart('trilio-data-mover-api')

    reactive.set_state('charm.installed')


@reactive.when('amqp.connected')
def setup_amqp_req(amqp):
    """Use the amqp interface to request access to the amqp broker using our
    local configuration.
    """
    amqp.request_access(username='dmapi',
                        vhost='openstack')
    dmapi.assess_status()


@reactive.when('shared-db.connected')
def setup_database(database):
    """On receiving database credentials, configure the database on the
    interface.
    """
    database.configure('dmapi', 'dmapi', hookenv.unit_private_ip())
    dmapi.assess_status()


@reactive.when('identity-service.connected')
def setup_endpoint(keystone):
    dmapi.setup_endpoint(keystone)
    dmapi.assess_status()


def render(*args):
    dmapi.render_configs(args)
    reactive.set_state('config.complete')
    dmapi.assess_status()


@reactive.when('charm.installed')
@reactive.when_not('cluster.available')
@reactive.when(*MINIMAL_INTERFACES)
def render_unclustered(*args):
    render(*args)


@reactive.when('charm.installed')
@reactive.when('cluster.available',
               *MINIMAL_INTERFACES)
def render_clustered(*args):
    render(*args)


@reactive.when('charm.installed')
@reactive.when('config.complete')
@reactive.when_not('db.synced')
def run_db_migration():
    dmapi.restart_all()
    reactive.set_state('db.synced')
    dmapi.assess_status()


@reactive.when('ha.connected')
def cluster_connected(hacluster):
    dmapi.configure_ha_resources(hacluster)


@reactive.hook('upgrade-charm')
def upgrade_charm():
    dmapi.install()
