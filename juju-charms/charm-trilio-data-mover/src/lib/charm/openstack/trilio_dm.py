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
import copy
import os
import charmhelpers.core.hookenv as hookenv
import charmhelpers.contrib.openstack.utils as os_utils

import charms.reactive as reactive

import charms_openstack.charm
import charms_openstack.plugins
import charms_openstack.plugins.trilio
import charms_openstack.adapters as os_adapters


charms_openstack.plugins.trilio.make_trilio_handlers()


VALID_BACKUP_TARGETS = ["nfs"]
TV_MOUNTS = "/var/triliovault-mounts"


class DataMoverDBAdapter(os_adapters.DatabaseRelationAdapter):
    """Get database URIs for the two nova databases"""

    @property
    def driver(self):
        return 'mysql+pymysql'

    @property
    def dmapi_uri(self):
        """URI for dmapi DB"""
        return self.get_uri(prefix="dmapi")





@os_adapters.config_property
def ceph_dir(ceph):
    return os.path.join("/var/lib/charm", hookenv.service_name())


@os_adapters.config_property
def rbd_user(ceph):
    return hookenv.service_name()


class NFSShareNotMountedException(Exception):
    """Signal that the trilio nfs share is not mount"""

    pass


class GhostShareAlreadyMountedException(Exception):
    """Signal that a ghost share is already mounted"""

    pass


class DataMoverRelationAdapaters(os_adapters.OpenStackAPIRelationAdapters):
    """
    Adapters collection for TrilioVault data mover
    """

    relation_adapters = {
        "ceph": charms_openstack.plugins.CephRelationAdapter,
        "amqp": os_adapters.RabbitMQRelationAdapter,
        "shared_db": DataMoverDBAdapter,
    }


class TrilioDataMoverBaseCharm(
    charms_openstack.plugins.TrilioVaultSubordinateCharm,
    charms_openstack.plugins.BaseOpenStackCephCharm,
):

    abstract_class = True

    release = "yoga"
    trilio_release = "5.2"

    service_name = name = "tvault-contego"

    adapters_class = DataMoverRelationAdapaters

    data_mover_conf = "/etc/triliovault-datamover/triliovault-datamover.conf"
    logrotate_conf = "/etc/logrotate.d/triliovault-datamover"
    datamover_log_conf = "/etc/triliovault-datamover/datamover_logging.conf"

    service_type = "data-mover"
    default_service = "triliovault-datamover"

    required_relations = ["amqp", "shared-db"]

    base_packages = ["python3-tvault-contego", "nfs-common", "python3-s3-fuse-plugin", "libguestfs-tools", "build-essential", "libperl-dev", "virt-v2v", "python3-apt", "python3-trilio-dms"]

    # configuration file permissions
    user = "root"
    group = "nova"

    # Setting an empty source_config_key activates special handling of release
    # selection suitable for subordinate charms
    source_config_key = ""

    # Use nova-common package to drive OpenStack Release versioning.
    os_release_pkg = "nova-common"
    package_codenames = os_utils.PACKAGE_CODENAMES

    @property
    def packages(self):
        _pkgs = copy.deepcopy(self.base_packages)
        return _pkgs

    # Set ceph keyring prefix to charm specific location
    @property
    def ceph_keyring_path_prefix(self):
        return os.path.join("/var/lib/charm", hookenv.service_name())

    @property
    def ceph_conf(self):
        return os.path.join(self.ceph_keyring_path, "ceph.conf")

    def configure_ceph_keyring(self, key, cluster_name=None):
        """Creates or updates a Ceph keyring file.

        :param key: Key data
        :type key: str
        :param cluster_name: (Optional) Name of Ceph cluster to operate on.
                             Defaults to value of ``self.ceph_cluster_name``.
        :type cluster_name: str
        :returns: Absolute path to keyring file
        :rtype: str
        :raises: subprocess.CalledProcessError, OSError
        """
        keyring_absolute_path = super().configure_ceph_keyring(
            key, cluster_name
        )
        # TODO: add support for custom permissions into charms.openstack
        if os.path.exists(keyring_absolute_path):
            # NOTE: triliovault access the keyring as the nova user, so
            #       set permissions so it can do this.
            os.chmod(keyring_absolute_path, 0o640)
            ceph_keyring = os.path.join(
                "/etc/ceph", os.path.basename(keyring_absolute_path)
            )
            # NOTE: triliovault needs a keyring in /etc/ceph as well as in the
            #       charm specific location for qemu commands to work
            if not os.path.exists(ceph_keyring):
                os.symlink(keyring_absolute_path, ceph_keyring)
        # NOTE: ensure /var/lib/charm is world readable - this will be the
        #       case with Python >= 3.7 but <= 3.6 has different behaviour
        os.chmod('/var/lib/charm', 0o755)
        return keyring_absolute_path

    def get_amqp_credentials(self):
        return ("datamover", "openstack")

    def get_database_setup(self):
        return [
            {
                "database": "dmapi",
                "username": "dmapi",
                "prefix": "dmapi",
            },
        ]

    dms_server_conf = "/etc/triliovault-dms/server.conf"
    dms_s3vaultfuse_conf = "/etc/triliovault-dms/s3vaultfuse-global.conf"

    @property
    def services(self):
        return ["tvault-contego", "trilio-dms-server"]

    @property
    def restart_map(self):
        _restart_map = {
            self.data_mover_conf: self.services,
            self.datamover_log_conf: self.services,
            self.dms_server_conf: ["trilio-dms-server"],
            self.dms_s3vaultfuse_conf: ["trilio-dms-server"],
        }
        if reactive.flags.is_flag_set("ceph.available"):
            _restart_map[self.ceph_conf] = self.services
        return _restart_map

    def custom_assess_status_check(self):
        return None, None

    def request_access_to_groups(self, ceph):
        """Request access to pool types needed for dm operation.

        :param ceph: ceph interface
        :type ceph: ceph-interface:CephClientRequires
        """
        for ceph_group in ("volumes", "images", "vms"):
            ceph.request_access_to_group(
                name=ceph_group,
                object_prefix_permissions={"class-read": ["rbd_children"]},
                permission="rwx",
            )

    @classmethod
    def trilio_version_package(cls):
        return 'python3-tvault-contego'


class TrilioDataMoverYoga52(
    TrilioDataMoverBaseCharm,
    charms_openstack.plugins.TrilioVaultCharmGhostAction
):

    # First release supported
    release = "yoga"
    trilio_release = "5.2"


class TrilioDataMoverZed52(
    TrilioDataMoverBaseCharm,
    charms_openstack.plugins.TrilioVaultCharmGhostAction
):

    # First release supported
    release = "zed"
    trilio_release = "5.2"


class TrilioDataMoverAntelope42(
    TrilioDataMoverBaseCharm,
    charms_openstack.plugins.TrilioVault42CharmGhostAction
):

    # First release supported
    release = "antelope"
    trilio_release = "5.2"

