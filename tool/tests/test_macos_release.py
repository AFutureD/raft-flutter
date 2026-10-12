import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('macos_release', Path(__file__).resolve().parents[1] / 'macos_release.py')
macos = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(macos)


class MacReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Raft.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Raft').write_bytes(b'\xcf\xfa\xed\xfe' + b'native-fixture')
        self.info = {'CFBundleIdentifier': 'app.raft.raftFlutter', 'CFBundleExecutable': 'Raft',
                     'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '41'}
        self.write_info()
        self.entitlements = self.root / 'Release.entitlements'
        self.entitlements.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
                                                    'com.apple.security.network.client': True}))

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def outputs(self, args):
        if args[0] == 'lipo':
            return b'arm64\n', b''
        if '--entitlements' in args:
            return self.entitlements.read_bytes(), b''
        return b'', b'Signature=adhoc\nTeamIdentifier=not set\n'

    def test_rejects_development_profile_before_signing(self):
        (self.app / 'Contents/embedded.provisionprofile').write_bytes(b'private-profile')
        with self.assertRaisesRegex(ValueError, 'provisioning profile'):
            macos.inventory(self.app)

    def test_rejects_symlink_to_outside_app(self):
        (self.app / 'Contents/external').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'external symlink'):
            macos.inventory(self.app)

    def test_accepts_framework_internal_symlink(self):
        (self.app / 'Contents/internal').symlink_to('MacOS')
        self.assertEqual(len(macos.inventory(self.app)), 1)

    def test_rejects_unreviewed_nested_bundle_entitlements(self):
        (self.app / 'Contents/Helper.xpc').mkdir()
        with self.assertRaisesRegex(ValueError, 'entitlement policy'):
            macos.inventory(self.app)

    def test_rejects_version_mismatch(self):
        self.info['CFBundleVersion'] = '40'
        self.write_info()
        with self.assertRaisesRegex(ValueError, 'release plan'):
            macos.verify(self.app, self.entitlements, '0.1.0', '41')

    def test_rejects_wrong_architecture(self):
        with patch.object(macos, 'output', return_value=(b'x86_64\n', b'')):
            with self.assertRaisesRegex(ValueError, 'architecture'):
                macos.verify(self.app, self.entitlements, '0.1.0', '41')

    def test_signature_claim_cannot_replace_actual_signature(self):
        def wrong_signature(args):
            if args[0] == 'codesign' and '-vv' in args:
                return b'', b'Authority=Apple Development\n'
            return self.outputs(args)
        with patch.object(macos, 'run'), patch.object(macos, 'output', side_effect=wrong_signature):
            with self.assertRaisesRegex(ValueError, 'ad-hoc'):
                macos.verify(self.app, self.entitlements, '0.1.0', '41')

    def test_rejects_changed_entitlements(self):
        def wrong_entitlements(args):
            if '--entitlements' in args:
                return plistlib.dumps({'com.apple.security.get-task-allow': True}), b''
            return self.outputs(args)
        with patch.object(macos, 'run'), patch.object(macos, 'output', side_effect=wrong_entitlements):
            with self.assertRaisesRegex(ValueError, 'entitlements'):
                macos.verify(self.app, self.entitlements, '0.1.0', '41')

    def test_records_verified_ad_hoc_metadata(self):
        with patch.object(macos, 'run'), patch.object(macos, 'output', side_effect=self.outputs):
            result = macos.verify(self.app, self.entitlements, '0.1.0', '41')
        self.assertEqual(result['architecture'], 'arm64')
        self.assertTrue(result['entitlementsVerified'])


if __name__ == '__main__':
    unittest.main()
