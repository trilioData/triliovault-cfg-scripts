from __future__ import absolute_import
from __future__ import print_function

import mock
import sys
#sys.path.append('build/builds/trilio-dm-api/lib')
import charm.openstack.dmapi as dmapi

import charms_openstack.test_utils as test_utils


class Helper(test_utils.PatchHelper):

    def setUp(self):
        super().setUp()
        self.patch_release(dmapi.DmapiCharm.release)

class TestOpenStackDmapi(Helper):

    def test_install(self):
        self.patch_object(dmapi.DmapiCharm.singleton, 'install')
        dmapi.install()
        self.install.assert_called_once_with()

    def test_setup_endpoint(self):
        self.patch_object(dmapi.DmapiCharm, 'service_name',
                          new_callable=mock.PropertyMock)
        self.patch_object(dmapi.DmapiCharm, 'region',
                          new_callable=mock.PropertyMock)
        self.patch_object(dmapi.DmapiCharm, 'public_url',
                          new_callable=mock.PropertyMock)
        self.patch_object(dmapi.DmapiCharm, 'internal_url',
                          new_callable=mock.PropertyMock)
        self.patch_object(dmapi.DmapiCharm, 'admin_url',
                          new_callable=mock.PropertyMock)
        self.service_name.return_value = 'type1'
        self.region.return_value = 'region1'
        self.public_url.return_value = 'public_url'
        self.internal_url.return_value = 'internal_url'
        self.admin_url.return_value = 'admin_url'
        keystone = mock.MagicMock()
        dmapi.setup_endpoint(keystone)
        keystone.register_endpoints.assert_called_once_with(
            'type1', 'region1', 'public_url', 'internal_url', 'admin_url')

    def test_render_configs(self):
        self.patch_object(dmapi.DmapiCharm.singleton, 'render_with_interfaces')
        dmapi.render_configs('interfaces-list')
        self.render_with_interfaces.assert_called_once_with(
            'interfaces-list')

class TestDmapiAdapters(Helper):

    @mock.patch('charmhelpers.core.hookenv.config')
    def test_dmapi_adapters(self, config):
        reply = {
            'keystone-api-version': '3',
        }
        config.side_effect = lambda: reply
        self.patch_object(
            dmapi.charms_openstack.adapters.APIConfigurationAdapter,
            'get_network_addresses')
        cluster_relation = mock.MagicMock()
        cluster_relation.relation_name = 'cluster'
        amqp_relation = mock.MagicMock()
        amqp_relation.relation_name = 'amqp'
        shared_db_relation = mock.MagicMock()
        shared_db_relation.relation_name = 'shared_db'
        other_relation = mock.MagicMock()
        other_relation.relation_name = 'other'
        other_relation.thingy = 'help'
        # verify that the class is created with a DmapiConfigurationAdapter
        b = dmapi.DmapiAdapters([amqp_relation,
                               cluster_relation,
                               shared_db_relation,
                               other_relation])
        # ensure that the relevant things got put on.
        self.assertTrue(
            isinstance(
                b.other,
                dmapi.charms_openstack.adapters.OpenStackRelationAdapter))
        self.assertTrue(
            isinstance(
                b.options,
                dmapi.charms_openstack.adapters.APIConfigurationAdapter))


class TestDmapiCharm(Helper):

    def test_install(self):
        b = dmapi.DmapiCharm()
        self.patch_object(dmapi.charms_openstack.charm.OpenStackCharm,
                          'configure_source')
        self.patch_object(dmapi.charms_openstack.charm.OpenStackCharm,
                          'install')
        b.install()
        self.configure_source.assert_called_with()
        self.install.assert_called_once_with()
