from contextlib import redirect_stdout
import io
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = json.loads((release.ROOT / 'tool/release-platforms.json').read_text())
        environment = patch.dict(release.os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def test_default_enables_windows_android_appimage_and_macos(self):
        result = release.release_plan(self.config, '')
        self.assertEqual([r['platform'] for r in result['include']], ['windows', 'android', 'appimage', 'macos'])
        self.assertEqual(result['include'][1]['arch'], 'arm64')

    def test_pull_requests_do_not_build_with_android_signing_secrets(self):
        result = release.release_plan(self.config, '', event='pull_request')
        self.assertEqual([r['platform'] for r in result['include']], ['windows', 'appimage', 'macos'])


    def test_manual_can_test_future_platforms(self):
        result = release.release_plan(self.config, 'windows, macos,linux,android')
        self.assertEqual(len(result['include']), 4)

    def test_invalid_or_duplicate_platform_is_rejected(self):
        for selection in ['windows,windows', 'windows,ios', 'flatpak', 'windows,flatpak', 'windows,', ',']:
            with self.subTest(selection=selection), self.assertRaises(ValueError):
                release.release_plan(self.config, selection)

    def test_tag_selects_version_and_run_counter_selects_build_number(self):
        for tag, version, asset in [('v0.1.0', '0.1.0', '0.1.0'),
                                    ('v0.1.0+2', '0.1.0', '0.1.0+2'),
                                    ('v0.1.0+0', '0.1.0', '0.1.0+0'),
                                    ('v0.1.0+01', '0.1.0', '0.1.0+01'),
                                    ('v0.1.1+7', '0.1.1', '0.1.1+7'),
                                    ('v0.2.0-rc.1+3', '0.2.0-rc.1', '0.2.0-rc.1+3')]:
            with self.subTest(tag=tag):
                identity = release.release_identity('0.1.0', '1', f'refs/tags/{tag}', 'push', '47')
                self.assertEqual(identity, {'version': version, 'build_number': '47',
                                            'tag': tag, 'asset_version': asset})

    def test_new_runs_increase_the_build_number_without_changing_app_version(self):
        first = release.release_identity('0.1.0', '1', 'refs/tags/v0.1.0+1', 'push', '47')
        second = release.release_identity('0.1.0', '1', 'refs/tags/v0.1.0+2', 'push', '48')
        self.assertEqual(first['version'], second['version'])
        self.assertGreater(int(second['build_number']), int(first['build_number']))
        self.assertNotEqual(first['asset_version'], second['asset_version'])

    def test_bad_tags_or_run_counters_stop_before_building(self):
        for ref in ['refs/heads/main', 'refs/tags/0.1.0', 'refs/tags/v０.１.０+1',
                    'refs/tags/v0.1.0+', 'refs/tags/v0.1.0+2+3',
                    'refs/tags/v0.1.0+bad', 'refs/tags/v0.1.0+2/extra']:
            with self.subTest(ref=ref), self.assertRaises(ValueError):
                release.release_identity('0.1.0', '1', ref, 'push', '47')
        for number in ['', '0', '-1', '1.5', '47\n']:
            with self.subTest(number=number), self.assertRaises(ValueError):
                release.release_identity('0.1.0', '1', 'refs/tags/v0.1.0+2', 'push', number)

    def test_local_fallback_and_manual_or_pr_run_counter(self):
        self.assertEqual(release.release_identity('0.1.0', '1'),
                         {'version': '0.1.0', 'build_number': '1', 'tag': '', 'asset_version': '0.1.0'})
        for event, ref in [('workflow_dispatch', 'refs/heads/main'), ('pull_request', 'refs/pull/1/merge')]:
            identity = release.release_identity('0.1.0', '1', ref, event, '48')
            self.assertEqual(identity['build_number'], '48')
            self.assertEqual(identity['tag'], '')
        manual_tag = release.release_identity('0.1.0', '1', 'refs/tags/v0.1.1+2', 'workflow_dispatch', '49')
        self.assertEqual(manual_tag['version'], '0.1.1')

    def test_tag_build_uses_version_override_and_auto_number_without_editing_pubspec(self):
        environment = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3+9',
                       'GITHUB_RUN_NUMBER': '214', 'RELEASE_VERSION': '1.2.3', 'RELEASE_BUILD_NUMBER': '214'}
        original = (release.APP / 'pubspec.yaml').read_bytes()
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'OUT', Path(temp)), \
                patch.dict(release.os.environ, environment), \
                patch.object(release, 'run', side_effect=RuntimeError('inspect build command')) as commands:
            with self.assertRaisesRegex(RuntimeError, 'inspect build command'):
                release.build('windows')
            command = commands.call_args.args[0]
            self.assertIn('--build-name=1.2.3', command)
            self.assertIn('--build-number=214', command)
            self.assertIn('--dart-define=RAFT_APP_VERSION=1.2.3', command)
            self.assertIn('--dart-define=RAFT_BUILD_NUMBER=214', command)
            self.assertNotIn('--build-number=9', command)
        self.assertEqual((release.APP / 'pubspec.yaml').read_bytes(), original)

    def test_plan_build_mismatch_is_rejected(self):
        with patch.dict(release.os.environ, {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3+9',
                                             'GITHUB_RUN_NUMBER': '214', 'RELEASE_BUILD_NUMBER': '213'}), \
                patch.object(release, 'run') as commands, self.assertRaises(ValueError):
            release.build('windows')
        commands.assert_not_called()

    def test_tag_suffix_is_kept_in_packaging_and_provenance(self):
        def package(stage):
            stage.mkdir()
            (stage / 'raft_flutter.exe').write_bytes(b'compiled bytes')

        environment = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v1.2.3+9', 'GITHUB_RUN_NUMBER': '214'}
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'OUT', Path(temp)), \
                patch.dict(release.os.environ, environment), patch.object(release, 'run'), \
                patch.object(release, 'capture', return_value='abc'), \
                patch.object(release, 'windows_package', side_effect=package), redirect_stdout(io.StringIO()):
            release.build('windows')
            receipt = json.loads((Path(temp) / 'raft-flutter-1.2.3+9-windows-x64.json').read_text())
            self.assertEqual(receipt['artifact'], 'raft-flutter-1.2.3+9-windows-x64.zip')
            self.assertEqual((receipt['version'], receipt['buildNumber'], receipt['releaseTag']),
                             ('1.2.3', '214', 'v1.2.3+9'))

    def test_version_requires_positive_android_build_number(self):
        self.assertEqual(release.version_info('name: raft\nversion: 1.2.3-rc.1+42\n'), ('1.2.3-rc.1', '42'))
        for text in ['version: 1.2.3', 'version: 1.2.3+0', 'version: not-a-version+1']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                release.version_info(text)

    def test_formal_build_passes_plain_version_to_about_and_clears_inherited_defines(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(release, 'OUT', Path(temp)), \
                    patch.dict(release.os.environ, {'DART_DEFINES': 'private-inherited-value'}), \
                    patch.object(release, 'run', side_effect=RuntimeError('stop after command')) as commands:
                with self.assertRaisesRegex(RuntimeError, 'stop after command'):
                    release.build('windows')
                version, number = release.version_info((release.APP / 'pubspec.yaml').read_text())
                command = commands.call_args.args[0]
                self.assertIn(f'--build-name={version}', command)
                self.assertIn(f'--dart-define=RAFT_APP_VERSION={version}', command)
                self.assertIn(f'--build-number={number}', command)
                self.assertNotIn('DART_DEFINES', commands.call_args.kwargs['env'])

    def test_appimage_compiles_linux_without_android_keys(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'OUT', Path(temp)), \
                patch.object(release, 'run', side_effect=RuntimeError('captured')) as commands:
            with self.assertRaisesRegex(RuntimeError, 'captured'):
                release.build('appimage')
            command = commands.call_args.args[0]
            self.assertIn('linux', command)
            self.assertNotIn('appimage', command)
            self.assertIn('--target=lib/main.dart', command)

    def test_android_missing_secrets_never_invokes_flutter(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(release, 'OUT', Path(temp)), \
                patch.dict(release.os.environ, {}, clear=True), patch.object(release, 'run') as commands:
            with self.assertRaisesRegex(ValueError, 'all four'):
                release.build('android')
            commands.assert_not_called()

    def test_android_build_is_arm64_only_and_temp_key_is_cleaned_on_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            environment = {'RAFT_ANDROID_KEYSTORE_BASE64': base64.b64encode(b'key bytes').decode(),
                           'RAFT_ANDROID_STORE_PASSWORD': 'store', 'RAFT_ANDROID_KEY_PASSWORD': 'key',
                           'RAFT_ANDROID_KEY_ALIAS': 'release'}
            with patch.object(release, 'OUT', Path(temp)), \
                    patch.dict(release.os.environ, environment, clear=True), \
                    patch.object(release, 'run', side_effect=RuntimeError('build failed')) as commands:
                with self.assertRaisesRegex(RuntimeError, 'build failed'):
                    release.build('android')
                command = commands.call_args.args[0]
                env = commands.call_args.kwargs['env']
                self.assertIn('--target-platform=android-arm64', command)
                self.assertIn('--split-per-abi', command)
                self.assertEqual(env['RAFT_ANDROID_SIGNING_REQUIRED'], 'true')
                self.assertNotIn('RAFT_ANDROID_KEYSTORE_BASE64', env)
                self.assertFalse(Path(env['RAFT_ANDROID_KEYSTORE_PATH']).exists())

    def test_android_verification_rejects_wrong_identity_version_abi_debug_and_certificate(self):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / 'release.apk'
            cert = b'release certificate'
            badging = "package: name='app.raft.raft_flutter' versionCode='2001' versionName='0.1.0'\n"
            signatures = f'Signer #1 certificate SHA-256 digest: {hashlib.sha256(cert).hexdigest()}\n'
            env = {'ANDROID_HOME': temp, 'RAFT_ANDROID_KEY_ALIAS': 'release'}

            def write_apk(abi):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr(f'lib/{abi}/libapp.so', b'native bytes')

            write_apk('arm64-v8a')
            for label in ['Signer #1', 'V2 Signer:', 'V3 Signer #1:', 'V3.0 Signer:', 'V3.1 Signer:', 'V4 Signer:']:
                output = signatures.replace('Signer #1', label)
                with self.subTest(label=label), \
                        patch.object(release.subprocess, 'check_output', side_effect=[badging, cert, output]):
                    result = release.verify_android(apk, Path(temp) / 'key.jks', env, '0.1.0', '1')
            self.assertEqual(result['versionCode'], 2001)
            self.assertEqual(result['certificateSHA256'], hashlib.sha256(cert).hexdigest())
            for invalid in [badging.replace('app.raft.raft_flutter', 'app.raft.raft_flutter.linkperf'),
                            badging.replace('2001', '2002'), badging.replace('0.1.0', '0.2.0'),
                            badging + 'application-debuggable\n']:
                with self.subTest(badging=invalid), \
                        patch.object(release.subprocess, 'check_output', return_value=invalid), \
                        self.assertRaises(ValueError):
                    release.verify_android(apk, Path(temp) / 'key.jks', env, '0.1.0', '1')
            write_apk('x86_64')
            with patch.object(release.subprocess, 'check_output', return_value=badging), \
                    self.assertRaisesRegex(ValueError, 'only ARM64'):
                release.verify_android(apk, Path(temp) / 'key.jks', env, '0.1.0', '1')
            write_apk('arm64-v8a')
            with patch.object(release.subprocess, 'check_output', side_effect=[badging, cert, '']), \
                    self.assertRaisesRegex(ValueError, 'signature differs'):
                release.verify_android(apk, Path(temp) / 'key.jks', env, '0.1.0', '1')

    def fixture(self, directory, platform='windows'):
        artifact = directory / 'raft.zip'
        artifact.write_bytes(b'compiled bundle')
        receipt = {'platform': platform, 'arch': 'x64', 'version': '0.1.0', 'commit': 'abc',
                   'buildNumber': '1', 'releaseTag': 'v0.1.0',
                   'artifact': artifact.name, 'bytes': artifact.stat().st_size,
                   'sha256': release.digest(artifact)}
        (directory / 'receipt.json').write_text(json.dumps(receipt))
        return artifact, receipt

    def test_verified_artifacts_produce_checksums(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            artifact, receipt = self.fixture(directory)
            matrix = release.release_plan(self.config, 'windows')
            _, files, checksums = release.verify_artifacts(directory, matrix, '0.1.0', 'abc')
            self.assertEqual(files, [artifact])
            self.assertEqual(checksums, f"{receipt['sha256']}  raft.zip\n")

    def test_partial_platform_set_is_never_publishable(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            matrix = release.release_plan(self.config, 'windows,linux')
            with self.assertRaises(ValueError):
                release.verify_artifacts(directory, matrix, '0.1.0', 'abc')

    def test_changed_bytes_or_source_are_never_publishable(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            artifact, _ = self.fixture(directory)
            matrix = release.release_plan(self.config, 'windows')
            for version, commit in [('0.2.0', 'abc'), ('0.1.0', 'def')]:
                with self.assertRaises(ValueError):
                    release.verify_artifacts(directory, matrix, version, commit)
            artifact.write_bytes(b'modified bundle')
            with self.assertRaises(ValueError):
                release.verify_artifacts(directory, matrix, '0.1.0', 'abc')

    def test_receipt_cannot_escape_artifact_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            _, receipt = self.fixture(directory)
            receipt['artifact'] = '../raft.zip'
            (directory / 'receipt.json').write_text(json.dumps(receipt))
            with self.assertRaises(ValueError):
                release.verify_artifacts(directory, release.release_plan(self.config, 'windows'), '0.1.0', 'abc')

    def test_wrong_build_number_or_tag_is_never_publishable(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            self.fixture(directory)
            matrix = release.release_plan(self.config, 'windows')
            for number, tag in [('2', 'v0.1.0'), ('1', 'v0.1.0+2')]:
                with self.subTest(number=number, tag=tag), self.assertRaises(ValueError):
                    release.verify_artifacts(directory, matrix, '0.1.0', 'abc', number, tag)


if __name__ == '__main__':
    unittest.main()
