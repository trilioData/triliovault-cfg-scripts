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
import socket

import charms_openstack.charm as charm
import charms.reactive as reactive
from charmhelpers.core.templating import render
from charmhelpers.core import hookenv
from charmhelpers.core import host

# This charm's library contains all of the handler code associated with
# dmapi
import charm.openstack.dmapi as dmapi  # noqa

DMS_CONF_DIR = '/etc/triliovault-dms'
DMS_CLIENT_CONF = os.path.join(DMS_CONF_DIR, 'client.conf')

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

    # Must run before render_with_interfaces() below: /var/log/triliovault/
    # is nova:nova 755, so the dmapi user can't create a new log file there
    # itself. If render_with_interfaces() restarts tvault-datamover-api
    # (e.g. on fresh install, or any restart_map-tracked template content
    # change) before this file exists with dmapi ownership, the service
    # fails trying to open its own log file.
    _ensure_dmapi_log_file()

    with charm.provide_charm_instance() as charm_class:
        charm_class.render_with_interfaces(args)
        charm_class.assess_status()

    reactive.set_flag("config.rendered")


def _ensure_dmapi_log_file():
    """Pre-create the dmapi log file with correct ownership so the service can write to it.

    /var/log/triliovault/ is nova:nova 755 — the dmapi user cannot create a
    new file there itself.
    """
    log_dir = '/var/log/triliovault'
    os.makedirs(log_dir, exist_ok=True)
    dmapi_uid = pwd.getpwnam('dmapi').pw_uid
    dmapi_gid = grp.getgrnam('dmapi').gr_gid
    log_file = os.path.join(log_dir, 'triliovault-datamover-api.log')
    if not os.path.exists(log_file):
        open(log_file, 'w').close()
    os.chown(log_file, dmapi_uid, dmapi_gid)


def _existing_db_url():
    """Return the db_url currently in client.conf on disk, or '' if none."""
    if not os.path.exists(DMS_CLIENT_CONF):
        return ''
    with open(DMS_CLIENT_CONF) as f:
        for line in f:
            if line.startswith('db_url'):
                _, _, value = line.partition('=')
                return value.strip()
    return ''


def _build_dms_client_context():
    """Build the render context for the DMS client.conf, or None if not ready.

    db_url is left empty until mysql-innodb-cluster has answered this charm's
    'workloadmgr' shared-db request; see DmapiCharm.get_database_setup().
    """
    amqp = reactive.endpoint_from_flag('amqp.available')
    if amqp is None:
        return None

    transport_url = (
        f"rabbit://{amqp.username()}:{amqp.password()}"
        f"@{amqp.private_address()}:{amqp.ssl_port() or 5672}/{amqp.vhost()}"
    )

    db_ep = reactive.endpoint_from_flag('shared-db.available')
    wlm_db_password = db_ep.password(prefix='wlm') if db_ep else None
    if wlm_db_password:
        mysql_host = db_ep.db_host() or '127.0.0.1'
        db_url = ("mysql+pymysql://workloadmgr:"
                  f"{wlm_db_password}@{mysql_host}:3306/workloadmgr")
    else:
        # Keep whatever is already on disk rather than blanking a working
        # db_url: the credentials can be briefly absent from relation data
        # (e.g. while the mysql-router subordinate restarts), and writing an
        # empty db_url would break every backup target mount until the next
        # hook restored it. Empty only on a genuine fresh install.
        db_url = _existing_db_url()
        hookenv.log("workloadmgr DB credentials not on shared-db yet; "
                    "keeping existing db_url (%s)."
                    % ("present" if db_url else "empty"))

    return {
        'rabbitmq_url': transport_url,
        'db_url': db_url,
        'node_id': socket.getfqdn(),
    }


def _dms_client_conf_is_stale(context):
    """True if client.conf on disk doesn't already hold the expected values.

    Mirrors _dms_server_conf_is_stale() in charm-trilio-data-mover: a package
    (re)install can silently reset client.conf to its blank default without any
    relation data changing, which data_changed() alone cannot detect
    (TVAULT-7521).
    """
    if not os.path.exists(DMS_CLIENT_CONF):
        return True
    with open(DMS_CLIENT_CONF) as f:
        content = f.read()
    return any(
        "{} = {}".format(key, context[key]) not in content
        for key in ('rabbitmq_url', 'db_url')
    )


def _ensure_dms_server_disabled():
    """Keep trilio-dms-server stopped and disabled on DMAPI nodes.

    Only the DMS *client* library is used here, but python3-trilio-dms ships
    the server's systemd unit and debhelper's postinst enables and starts it
    on every (re)install. This must therefore be re-asserted on each hook, not
    only when client.conf changes -- a package reinstall can re-enable the
    service without altering the rendered config. Both calls are idempotent
    and are no-ops once the unit is already stopped and disabled.
    """
    host.service('disable', 'trilio-dms-server')
    host.service('stop', 'trilio-dms-server')


def _write_dms_client_config(context):
    """Write the DMS client.conf and restart the datamover API."""
    root_uid = pwd.getpwnam('root').pw_uid
    dmapi_gid = grp.getgrnam('dmapi').gr_gid

    os.makedirs(DMS_CONF_DIR, exist_ok=True)
    os.chown(DMS_CONF_DIR, root_uid, dmapi_gid)

    render(
        source='etc_triliovault-dms_client.conf',
        target=DMS_CLIENT_CONF,
        context=context,
    )
    os.chmod(DMS_CLIENT_CONF, 0o640)
    os.chown(DMS_CLIENT_CONF, root_uid, dmapi_gid)
    hookenv.log("DMS client config rendered for dmapi from shared-db.")
    host.service_restart('tvault-datamover-api')


def render_dmapi_and_dms_configs():
    """Re-run the log file setup and the DMS client.conf render.

    Called from the update-trilio action: charms.reactive actions never go
    through the reactive hook-dispatch loop, so render_config() would
    otherwise not re-run until some later hook fires (TVAULT-7521). The render
    is unconditional — the package upgrade the action just performed can have
    reset client.conf to its blank on-disk default even though the computed
    context is unchanged, which would make the data_changed() guard in
    render_dms_client_config() skip it.
    """
    _ensure_dmapi_log_file()
    _ensure_dms_server_disabled()
    context = _build_dms_client_context()
    if context is None:
        return
    reactive.helpers.data_changed('dmapi.dms-client-conf', context)
    _write_dms_client_config(context)


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


@reactive.when_not('is-update-status-hook')
@reactive.when('shared-db.available')
@reactive.when('amqp.available')
def render_dms_client_config(*args):
    """Render the DMS client config with the workloadmgr DB credentials.

    Both the password and the matching 'workloadmgr'@<dmapi-host> grant come
    from this charm's own shared-db request (see get_database_setup()). This
    used to be sourced from a dedicated wlm-db relation to trilio-wlm, which
    supplied a valid password but no grant for this host, so every backup
    target mount failed with ERROR 1045 (TVAULT-7592).
    """
    # Re-asserted every hook, deliberately outside the change guard below --
    # see _ensure_dms_server_disabled().
    _ensure_dms_server_disabled()

    context = _build_dms_client_context()
    if context is None:
        return

    # These flags stay set for the lifetime of the relations, so this handler
    # runs on essentially every hook. Without these guards the
    # service_restart() in _write_dms_client_config() bounced
    # tvault-datamover-api continuously (observed every ~4-5 minutes), killing
    # any snapshot that happened to be mid-transfer (TVAULT-7592).
    inputs_unchanged = not reactive.helpers.data_changed(
        'dmapi.dms-client-conf', context)
    if inputs_unchanged and not _dms_client_conf_is_stale(context):
        return

    _write_dms_client_config(context)


@reactive.when("shared-db.available")
@reactive.when_not("dmapi-db.ready")
def check_dmapi_db():
    db_ep = reactive.endpoint_from_flag('shared-db.available')
    if db_ep:
        if db_ep.password(prefix='dmapi'):
            reactive.set_flag("dmapi-db.ready")
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
