"""Exercise deployment transactions using fake SDK/ADB, never a real device."""
import copy
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import android_app as android


def dump(version=4001, inode=123, installed=True):
    return (f'Package [app.raft.raft_flutter]:\n    versionCode={version} minSdk=24 targetSdk=37\n'
            f'    User 0: ceDataInode={inode} deDataInode=456 installed={str(installed).lower()}\n'
            '      firstInstallTime=2026-10-10 12:34:56\n    User 10: installed=false\n')


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='raft-install-test-')
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / 'candidate.apk'
        with zipfile.ZipFile(self.apk, 'w') as archive:
            archive.writestr('lib/arm64-v8a/libflutter.so', 'fake fixture')
        self.commands = []
        self.receipts = []
        self.version = 4001
        self.target = 37
        self.package = android.PACKAGE
        self.old = dump()
        self.new = dump()
        self.mismatch_certificate = False
        self.fail_install = False
        self.corrupt_after = False
        self.installed = False

    def fake_call(self, argv):
        argv = [str(arg) for arg in argv]
        self.commands.append(argv)
        if argv[0] == 'aapt':
            return (f"package: name='{self.package}' versionCode='{self.version}'\n"
                    f"targetSdkVersion:'{self.target}'\nlaunchable-activity: name='app.raft.raft_flutter.MainActivity'\n")
        if argv[0] == 'apksigner':
            cert = 'b' if self.mismatch_certificate and Path(argv[-1]).name == 'installed.apk' else 'a'
            return f'Signer #1 certificate SHA-256 digest: {cert * 64}\n'
        if argv[3:6] == ['shell', 'dumpsys', 'package']:
            return self.new if self.installed else self.old
        if argv[3:6] == ['shell', 'pm', 'path']:
            return 'package:ignore\n' if self.old == 'missing' else 'package:/data/app/~~fixture==/raft==/base.apk\n'
        if argv[3] == 'pull':
            Path(argv[-1]).write_bytes(b'changed' if self.installed and self.corrupt_after else self.apk.read_bytes())
            return 'pulled\n'
        if argv[3] == 'install':
            if self.fail_install:
                raise android.SafetyError('INSTALL_FAILED_UPDATE_INCOMPATIBLE')
            self.installed = True
            return 'Success\n'
        if argv[3:6] == ['shell', 'am', 'start']:
            return 'Starting\n'
        self.fail(f'unexpected command {argv}')

    def update(self, **kw):
        return android.update(self.apk, 'owned-test-device', ('adb', 'aapt', 'apksigner'),
                              lambda report: self.receipts.append(copy.deepcopy(report)), run=self.fake_call, **kw)

    def mutations(self):
        return [cmd for cmd in self.commands if cmd[0] == 'adb' and cmd[3] == 'install']

    def test_update_verifies_artifact_and_data_before_launch(self):
        report = self.update(launch=True)
        self.assertEqual(report['status'], 'verified')
        self.assertEqual(report['before'], report['after'])
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual(self.mutations()[0][:-1], ['adb', '-s', 'owned-test-device', 'install', '-r', '--user', '0'])
        self.assertEqual(Path(self.mutations()[0][-1]).name, 'candidate.apk')
        self.assertNotEqual(self.mutations()[0][-1], str(self.apk))
        self.assertEqual(self.commands[-1][3:6], ['shell', 'am', 'start'])
        self.assertNotIn('uninstall', str(self.commands))
        self.assertNotIn('clear', str(self.commands))

    def test_read_only_check_never_installs_or_launches(self):
        self.assertEqual(self.update(check_only=True, launch=True)['status'], 'preflight-passed')
        self.assertFalse(self.mutations())
        self.assertNotIn('start', str(self.commands))

    @unittest.skipIf(os.name == 'nt', 'Android installer locking requires a macOS/Linux host')
    def test_same_device_updates_are_serialized_and_lock_releases(self):
        directory = Path(self.temp.name) / 'locks'
        with android.update_lock('owned-test-device', directory):
            with self.assertRaises(android.SafetyError):
                with android.update_lock('owned-test-device', directory):
                    self.fail('concurrent update must not enter')
            with android.update_lock('another-owned-device', directory):
                pass
        with android.update_lock('owned-test-device', directory):
            pass

    def test_sdk37_signature_output_and_duplicate_scheme_certificates(self):
        digest = 'a' * 64
        output = f'V2 Signer: certificate SHA-256 digest: {digest}\nV3 Signer: certificate SHA-256 digest: {digest}\n'
        self.assertEqual(android.certificate(self.apk, 'apksigner', lambda _: output), [digest])

    def test_identity_downgrade_signature_and_missing_app_block_before_mutation(self):
        cases = [('package', android.LAB_PACKAGE), ('version', 2001), ('target', 36),
                 ('mismatch_certificate', True), ('old', 'missing'),
                 ('old', dump(installed=False)), ('old', dump(inode=0))]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                original = getattr(self, field)
                setattr(self, field, value)
                with self.assertRaises(android.SafetyError):
                    self.update(launch=True)
                self.assertFalse(self.mutations())
                setattr(self, field, original)
                self.commands.clear()

    def test_failed_install_does_not_retry_uninstall_or_launch(self):
        self.fail_install = True
        with self.assertRaises(android.SafetyError):
            self.update(launch=True)
        self.assertEqual(len(self.mutations()), 1)
        self.assertEqual(self.receipts[-1]['status'], 'failed')
        self.assertNotIn('uninstall', str(self.commands))
        self.assertNotIn('start', str(self.commands))

    def test_changed_data_identity_or_wrong_artifact_stops_before_launch(self):
        for changed in ('inode', 'hash'):
            with self.subTest(changed=changed):
                self.commands.clear()
                self.installed = False
                self.new = dump(inode=789) if changed == 'inode' else dump()
                self.corrupt_after = changed == 'hash'
                with self.assertRaises(android.SafetyError):
                    self.update(launch=True)
                self.assertEqual(len(self.mutations()), 1)
                self.assertNotIn('start', str(self.commands))

    def test_flutter_drive_namespace_cleanup_path_is_blocked(self):
        arguments = ['drive', '-d', 'owned-test-device', '--profile']
        for extra in ([], ['--keep-app-running'],
                      ['--keep-app-running', f'--use-application-binary={self.apk}'],
                      ['--keep-app-running', '--no-keep-app-running', f'--use-application-binary={self.apk}']):
            with self.subTest(extra=extra), self.assertRaises(android.SafetyError):
                android.flutter_guard(arguments + extra, tools=('adb', 'aapt', 'apksigner'), run=self.fake_call)
        self.package = android.LAB_PACKAGE
        android.flutter_guard(arguments + ['--keep-app-running', f'--use-application-binary={self.apk}'],
                              tools=('adb', 'aapt', 'apksigner'), run=self.fake_call)
        self.assertFalse(self.mutations())

    def test_mobile_auto_install_blocked_desktop_and_widget_tests_allowed(self):
        for command in ('run', 'test', 'install'):
            with self.assertRaises(android.SafetyError):
                android.flutter_guard([command, '-d', 'owned-test-device'])
            with self.assertRaises(android.SafetyError):
                android.flutter_guard(['--verbose', command, '-d', 'owned-test-device'])
        for arguments in (['run', '-d', 'macos'], ['test', 'test/widget_test.dart'], ['build', 'apk']):
            android.flutter_guard(arguments)

    def test_non_arm64_artifact_is_rejected_before_mutation(self):
        with zipfile.ZipFile(self.apk, 'a') as archive:
            archive.writestr('lib/x86_64/libflutter.so', 'another ABI')
        with self.assertRaises(android.SafetyError):
            self.update()
        self.assertFalse(self.mutations())

    def test_lab_protects_physical_app_but_allows_empty_named_emulator(self):
        tools = ('adb', 'aapt', 'apksigner')
        self.assertEqual(android.protected_state('owned-test-device', tools, self.fake_call), android.package_state(dump()))
        absent = lambda _: 'Unable to find package: app.raft.raft_flutter\n'
        with self.assertRaises(android.SafetyError):
            android.protected_state('owned-test-device', tools, absent)
        self.assertIsNone(android.protected_state('emulator-5580', tools, absent))


if __name__ == '__main__':
    unittest.main()
