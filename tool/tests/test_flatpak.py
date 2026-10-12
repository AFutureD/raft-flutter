import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('raft_flatpak', Path(__file__).resolve().parents[1] / 'flatpak.py')
flatpak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(flatpak)


class FlatpakTests(unittest.TestCase):
    def test_permissions_allow_platform_services_without_host_home_access(self):
        spec = flatpak.manifest(Path('/tmp/prepared-payload'))
        self.assertEqual(spec['runtime-version'], '51')
        self.assertEqual(spec['app-id'], 'app.raft.raft_flutter')
        self.assertIn('--socket=wayland', spec['finish-args'])
        self.assertIn('--socket=fallback-x11', spec['finish-args'])
        self.assertIn('--talk-name=org.freedesktop.secrets', spec['finish-args'])
        self.assertIn('--talk-name=org.freedesktop.Notifications', spec['finish-args'])
        self.assertFalse(any(x.startswith(('--filesystem=', '--socket=session-bus', '--socket=system-bus'))
                             for x in spec['finish-args']))



if __name__ == '__main__':
    unittest.main()
