import mock
import unittest
import sys
sys.path.append('build/builds/trilio-horizon-plugin/reactive')
import trilio_horizon_plugin as plugin

_when_args = {}
_when_not_args = {}


def mock_hook_factory(d):

    def mock_hook(*args, **kwargs):

        def inner(f):
            # remember what we were passed.  Note that we can't actually
            # determine the class we're attached to, as the decorator only gets
            # the function.
            try:
                d[f.__name__].append(dict(args=args, kwargs=kwargs))
            except KeyError:
                d[f.__name__] = [dict(args=args, kwargs=kwargs)]
            return f
        return inner
    return mock_hook


class Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._patched_when = mock.patch('charms.reactive.when',
                                       mock_hook_factory(_when_args))
        cls._patched_when_started = cls._patched_when.start()
        cls._patched_when_not = mock.patch('charms.reactive.when_not',
                                           mock_hook_factory(_when_not_args))
        cls._patched_when_not_started = cls._patched_when_not.start()
        # force requires to rerun the mock_hook decorator:
        # try except is Python2/Python3 compatibility as Python3 has moved
        # reload to importlib.
        try:
            reload(plugin)
        except NameError:
            import importlib
            importlib.reload(plugin)

    @classmethod
    def tearDownClass(cls):
        cls._patched_when.stop()
        cls._patched_when_started = None
        cls._patched_when = None
        cls._patched_when_not.stop()
        cls._patched_when_not_started = None
        cls._patched_when_not = None
        # and fix any breakage we did to the module
        try:
            reload(plugin)
        except NameError:
            import importlib
            importlib.reload(plugin)

    def setUp(self):
        self._patches = {}
        self._patches_start = {}

    def tearDown(self):
        for k, v in self._patches.items():
            v.stop()
            setattr(self, k, None)
        self._patches = None
        self._patches_start = None

    def patch(self, obj, attr, return_value=None, side_effect=None):
        mocked = mock.patch.object(obj, attr)
        self._patches[attr] = mocked
        started = mocked.start()
        started.return_value = return_value
        started.side_effect = side_effect
        self._patches_start[attr] = started
        setattr(self, attr, started)

    def test_registered_hooks(self):
        # test that the hooks actually registered the relation expressions that
        # are meaningful for this interface: this is to handle regressions.
        # The keys are the function names that the hook attaches to.
        when_patterns = {
            'stop_trilio_horizon_plugin': ('trilio-horizon-plugin.stopping', ),
        }
        when_not_patterns = {
            'install_trilio_horizon_plugin': (
                'trilio-horizon-plugin.installed', ), }
        # check the when hooks are attached to the expected functions
        for t, p in [(_when_args, when_patterns),
                     (_when_not_args, when_not_patterns)]:
            for f, args in t.items():
                # check that function is in patterns
                self.assertTrue(f in p.keys(),
                                "{} not found".format(f))
                # check that the lists are equal
                lists = []
                for a in args:
                    lists += a['args'][:]
                self.assertEqual(sorted(lists), sorted(p[f]),
                                 "{}: incorrect state registration".format(f))

    def test_install_plugin(self):
         self.patch(plugin, 'install_plugin')
         plugin.install_plugin('1.2.3.4', 'version')
         self.install_plugin.assert_called_once_with('1.2.3.4', 'version')

    def test_uninstall_plugin(self):
         self.patch(plugin, 'uninstall_plugin')
         plugin.uninstall_plugin()
         self.uninstall_plugin.assert_called_once_with()

    def test_install_trilio_horizon_plugin(self):
         self.patch(plugin, 'install_trilio_horizon_plugin')
         plugin.install_trilio_horizon_plugin()
         self.install_trilio_horizon_plugin.assert_called_once_with()

    def test_stop_trilio_horizon_plugin(self):
         self.patch(plugin, 'status_set')
         self.patch(plugin, 'remove_state')
         self.patch(plugin, 'uninstall_plugin')
         self.uninstall_plugin.return_value = True
         plugin.stop_trilio_horizon_plugin()
         self.status_set.assert_called_with(
             'maintenance', 'Stopping...')
         self.remove_state.assert_called_with('trilio-horizon-plugin.stopping')

    def test_invalid_ip(self):
         self.patch(plugin, 'config')
         self.patch(plugin, 'status_set')
         self.patch(plugin, 'application_version_set')
         self.patch(plugin, 'validate_ip')
         self.validate_ip.return_value = False
         plugin.install_trilio_horizon_plugin()
         self.status_set.assert_called_with(
             'blocked',
             'Invalid IP address, please provide correct IP address')
         self.application_version_set.assert_called_with('Unknown')

    def test_valid_ip_install_pass(self):
         self.patch(plugin, 'config')
         self.config.return_value = '1.2.3.4'
         self.patch(plugin, 'status_set')
         self.patch(plugin, 'application_version_set')
         self.patch(plugin, 'validate_ip')
         self.validate_ip.return_value = True
         self.patch(plugin, 'get_new_version')
         self.get_new_version.return_value = 'Version'
         self.patch(plugin, 'install_plugin')
         self.install_plugin.return_value = True
         plugin.install_trilio_horizon_plugin()
         self.install_plugin.assert_called_with('1.2.3.4', 'Version')
         self.status_set.assert_called_with(
             'active', 'Ready...')
         self.application_version_set.assert_called_with('Version')

    def test_valid_ip_install_fail(self):
         self.patch(plugin, 'config')
         self.config.return_value = '1.2.3.4'
         self.patch(plugin, 'status_set')
         self.patch(plugin, 'application_version_set')
         self.patch(plugin, 'validate_ip')
         self.validate_ip.return_value = True
         self.patch(plugin, 'get_new_version')
         self.get_new_version.return_value = 'Version'
         self.patch(plugin, 'install_plugin')
         self.install_plugin.return_value = False
         plugin.install_trilio_horizon_plugin()
         self.install_plugin.assert_called_with('1.2.3.4', 'Version')
         self.status_set.assert_called_with(
             'blocked',
             'Packages installation failed.....retry..')
         self.application_version_set.assert_not_called()
