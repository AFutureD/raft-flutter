"""Release state transitions against a GitHub CLI double; no remote writes."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('release_publish', Path(__file__).resolve().parents[1] / 'release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
READ_RELEASE = release.read_release


class GitHub:
    def __init__(self):
        self.remote = None
        self.payloads = {}
        self.commands = []
        self.fail_after = None

    def read(self, tag, *, missing_ok=False):
        if self.remote is None and not missing_ok:
            raise subprocess.CalledProcessError(1, 'read')
        return copy.deepcopy(self.remote)

    def run(self, args, **kwargs):
        args = [str(a) for a in args]
        self.commands.append(args)
        action, tag = args[2:4]
        if action == 'create':
            self.remote = {'tag_name': tag, 'body': Path(args[args.index('--notes-file') + 1]).read_text(),
                           'draft': True, 'assets': [], 'immutable': False}
        elif action == 'upload':
            assert '--clobber' not in args
            for index, path in enumerate(map(Path, args[4:])):
                if self.fail_after == index:
                    self.fail_after = None
                    raise subprocess.CalledProcessError(1, args)
                assert path.name not in self.payloads, 'GitHub rejects duplicate asset names'
                data = path.read_bytes()
                self.payloads[path.name] = data
                self.remote['assets'].append({'name': path.name, 'size': len(data), 'state': 'uploaded',
                                             'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
        elif action == 'edit':
            self.remote['draft'] = False
            self.remote['prerelease'] = '--prerelease=true' in args
            self.remote['latest'] = '--latest=true' in args
        elif action == 'download':
            name = args[args.index('--pattern') + 1]
            Path(args[args.index('--dir') + 1], name).write_bytes(self.payloads[name])
        else:
            raise AssertionError(args)


class IndependentPublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.github = GitHub()
        self.config = json.loads((release.ROOT / 'tool/release-platforms.json').read_text())
        self.matrix = release.release_plan(self.config, '')
        environment = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF': 'refs/tags/v0.1.0+1',
                       'GITHUB_RUN_NUMBER': '47', 'GITHUB_REPOSITORY': 'owner/raft',
                       'RELEASE_MATRIX': json.dumps(self.matrix)}
        for context in [patch.dict(release.os.environ, environment, clear=True),
                        patch.object(release, 'OUT', self.directory),
                        patch.object(release, 'capture', return_value='abc'),
                        patch.object(release.release_notes, 'write', side_effect=self.write_notes),
                        patch.object(release, 'read_release', side_effect=self.github.read),
                        patch.object(release, 'run', side_effect=self.github.run)]:
            context.start()
            self.addCleanup(context.stop)

    def write_notes(self, path, tag, directory=None):
        Path(path).write_text('{"items": [], "nextCursor": null}\n')

    def test_prepare_attaches_client_release_notes_to_the_draft_only_once(self):
        release.prepare()
        create = self.github.commands[0]
        self.assertIn(str(self.directory / 'release-notes.json'), create)
        self.assertLess(create.index(str(self.directory / 'release-notes.json')), create.index('--verify-tag'))
        release.prepare()
        self.assertEqual(len(self.github.commands), 1, 'an existing draft is reused untouched')

    def test_prepare_stops_before_creating_a_draft_without_release_notes(self):
        with patch.object(release.release_notes, 'write', side_effect=ValueError('Add release notes')):
            with self.assertRaisesRegex(ValueError, 'Add release notes'):
                release.prepare()
        self.assertEqual(self.github.commands, [])

    def fixture(self, platform='windows'):
        folder = self.directory / platform
        folder.mkdir(exist_ok=True)
        identity = release.current_release()
        arch = self.config[platform]['arch']
        suffix = {'windows': 'zip', 'macos': 'zip', 'android': 'apk', 'linux': 'tar.gz', 'appimage': 'AppImage'}[platform]
        artifact = folder / f'raft-flutter-{identity["asset_version"]}-{platform}-{arch}.{suffix}'
        artifact.write_bytes(f'{platform} compiled bundle'.encode())
        receipt = {'platform': platform, 'arch': arch, 'version': identity['version'], 'commit': 'abc',
                   'buildNumber': '47', 'releaseTag': identity['tag'], 'flutter': '3.47.6',
                   'artifact': artifact.name, 'bytes': artifact.stat().st_size,
                   'sha256': release.digest(artifact), 'signing': 'verified by builder'}
        (folder / 'receipt.json').write_text(json.dumps(receipt))
        return folder, artifact, receipt

    def publish(self, platform='windows'):
        folder, _, _ = self.fixture(platform)
        with patch.object(release, 'OUT', folder):
            release.publish(platform)

    def test_first_success_is_public_without_any_sibling_artifacts(self):
        release.prepare()
        self.assertTrue(self.github.remote['draft'])
        self.assertFalse(self.github.payloads)
        self.publish()
        self.assertFalse(self.github.remote['draft'])
        self.assertTrue(self.github.remote['latest'])
        self.assertFalse(self.github.remote['prerelease'])
        self.assertEqual(set(self.github.payloads), {'raft-flutter-0.1.0+1-windows-x64.zip',
                         'CHECKSUMS-windows-x64.txt', 'build-manifest-windows-x64.json'})
        self.assertTrue(all(command[3] == 'v0.1.0+1' for command in self.github.commands))
        self.assertIn('Build number: 47.', self.github.remote['body'])
        manifest = json.loads(self.github.payloads['build-manifest-windows-x64.json'])
        self.assertEqual(manifest[0]['commit'], 'abc')
        self.assertEqual(manifest[0]['buildNumber'], '47')

    def test_real_lookup_reuses_draft_then_first_platform_publishes(self):
        release.prepare()
        draft = copy.deepcopy(self.github.remote)
        responses = [subprocess.CompletedProcess([], 1, '{"status":"404"}', 'not found'),
                     subprocess.CompletedProcess([], 0, json.dumps([[draft]]), '')]
        with patch.object(release, 'read_release', side_effect=READ_RELEASE), \
                patch.object(release.subprocess, 'run', side_effect=responses * 2):
            release.prepare()
            self.assertEqual(len(self.github.commands), 1, 'Do not create a duplicate draft')
            self.publish()
        self.assertFalse(self.github.remote['draft'])
        self.assertEqual(len(self.github.payloads), 3)

    def test_auxiliary_assets_have_canonical_lf_bytes_on_every_host(self):
        release.prepare()
        folder, artifact, receipt = self.fixture()
        with patch.object(release, 'OUT', folder):
            release.publish('windows')
        self.assertEqual(self.github.payloads['CHECKSUMS-windows-x64.txt'],
                         f'{receipt["sha256"]}  {artifact.name}\n'.encode('utf-8'))
        self.assertEqual(self.github.payloads['build-manifest-windows-x64.json'],
                         (json.dumps([receipt], indent=2) + '\n').encode('utf-8'))

    def test_partial_upload_stays_draft_and_retry_only_adds_missing_assets(self):
        release.prepare()
        self.github.fail_after = 1
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.github.remote['draft'])
        self.assertEqual(len(self.github.payloads), 1)
        first = copy.deepcopy(self.github.payloads)
        self.publish()
        self.assertFalse(self.github.remote['draft'])
        self.assertTrue(first.items() <= self.github.payloads.items())
        last_upload = [c for c in self.github.commands if c[2] == 'upload'][-1]
        self.assertEqual(len(last_upload[4:]), 2)

    def test_failed_later_platform_does_not_hide_or_change_successful_release(self):
        release.prepare()
        self.publish()
        first = copy.deepcopy(self.github.payloads)
        self.github.fail_after = 1
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish('android')
        self.assertFalse(self.github.remote['draft'])
        self.assertTrue(first.items() <= self.github.payloads.items())
        self.publish('android')
        self.assertTrue(first.items() <= self.github.payloads.items())
        self.assertEqual(len(self.github.payloads), 6)
        self.assertEqual(sum(c[2] == 'edit' for c in self.github.commands), 1)
        self.assertIn('CHECKSUMS-android-arm64.txt', self.github.payloads)

    def test_matching_prepare_and_publish_are_idempotent(self):
        release.prepare()
        self.publish()
        before = copy.deepcopy(self.github.commands)
        release.prepare()
        self.publish()
        self.assertEqual(self.github.commands, before)

    def test_changed_remote_asset_is_never_overwritten(self):
        release.prepare()
        self.publish()
        self.github.remote['assets'][0]['digest'] = 'sha256:' + '0' * 64
        before = copy.deepcopy(self.github.commands)
        with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
            self.publish()
        self.assertEqual(self.github.commands, before)

    def test_old_server_assets_are_downloaded_and_compared(self):
        release.prepare()
        self.publish()
        for asset in self.github.remote['assets']:
            asset.pop('digest')
        self.publish()
        self.assertEqual(sum(c[2] == 'upload' for c in self.github.commands), 1)
        self.assertEqual(sum(c[2] == 'download' for c in self.github.commands), 3)
        self.github.payloads['raft-flutter-0.1.0+1-windows-x64.zip'] = b'corrupted remote payload'
        with self.assertRaisesRegex(ValueError, 'refusing to overwrite'):
            self.publish()

    def test_tampered_local_bytes_source_build_tag_or_name_cannot_upload(self):
        release.prepare()
        folder, artifact, receipt = self.fixture()
        before = copy.deepcopy(self.github.commands)
        for field, value in [('commit', 'def'), ('buildNumber', '48'), ('releaseTag', 'v0.1.0+2'),
                             ('arch', 'arm64'), ('sha256', '0' * 64)]:
            with self.subTest(field=field):
                (folder / 'receipt.json').write_text(json.dumps({**receipt, field: value}))
                with patch.object(release, 'OUT', folder), self.assertRaises(ValueError):
                    release.publish('windows')
        artifact.rename(folder / 'sibling.apk')
        (folder / 'receipt.json').write_text(json.dumps({**receipt, 'artifact': 'sibling.apk'}))
        with patch.object(release, 'OUT', folder), self.assertRaisesRegex(ValueError, 'does not belong'):
            release.publish('windows')
        (folder / 'receipt.json').write_text(json.dumps({**receipt, 'artifact': 'sibling.apk'}))
        (folder / 'sibling.apk').write_bytes(b'tampered')
        with patch.object(release, 'OUT', folder), self.assertRaises(ValueError):
            release.publish('windows')
        self.assertEqual(self.github.commands, before)

    def test_changed_release_identity_plan_or_legacy_release_cannot_resume(self):
        release.prepare()
        original = copy.deepcopy(self.github.remote)
        for context in [patch.object(release, 'capture', return_value='def'),
                        patch.dict(release.os.environ, {'GITHUB_RUN_NUMBER': '48'}),
                        patch.dict(release.os.environ, {'GITHUB_REF': 'refs/tags/v0.1.0+2'}),
                        patch.dict(release.os.environ, {'RELEASE_MATRIX': json.dumps(release.release_plan(self.config, 'windows'))})]:
            with context, self.assertRaises(ValueError):
                release.prepare()
        self.github.remote['body'] = 'Legacy all-platform release'
        with self.assertRaisesRegex(ValueError, 'new tag'):
            release.prepare()
        self.github.remote = original
        self.assertEqual(len(self.github.commands), 1)

    def test_platform_outside_prepared_plan_cannot_publish(self):
        with patch.dict(release.os.environ, {'RELEASE_MATRIX': json.dumps(release.release_plan(self.config, 'windows'))}):
            release.prepare()
        with self.assertRaisesRegex(ValueError, 'not in the prepared'):
            self.publish('android')
        self.assertEqual(len(self.github.commands), 1)

    def test_manual_pr_or_branch_push_cannot_prepare_or_publish(self):
        for event, ref in [('workflow_dispatch', 'refs/tags/v0.1.0+1'), ('pull_request', 'refs/pull/1/merge'),
                           ('push', 'refs/heads/main')]:
            for action in [release.prepare, lambda: release.publish('windows')]:
                with patch.dict(release.os.environ, {'GITHUB_EVENT_NAME': event, 'GITHUB_REF': ref}), self.assertRaises(ValueError):
                    action()
        self.assertFalse(self.github.commands)

    def test_prerelease_is_not_latest(self):
        with patch.dict(release.os.environ, {'GITHUB_REF': 'refs/tags/v0.1.0-rc.1+1'}):
            release.prepare()
            self.publish()
        self.assertIn('--prerelease', self.github.commands[0])
        self.assertTrue(self.github.remote['prerelease'])
        self.assertFalse(self.github.remote['latest'])

    def test_immutable_release_cannot_be_appended_or_reprepared(self):
        release.prepare()
        self.github.remote['immutable'] = True
        with self.assertRaisesRegex(ValueError, 'mutable'):
            release.prepare()
        with self.assertRaisesRegex(ValueError, 'mutable'):
            self.publish()
        self.assertEqual(len(self.github.commands), 1)


class ReleaseLookupTests(unittest.TestCase):
    def test_draft_on_later_page_is_found_by_exact_tag(self):
        draft = {'id': 42, 'tag_name': 'v0.1.0+1', 'draft': True, 'assets': []}
        with patch.dict(release.os.environ, {'GITHUB_REPOSITORY': 'owner/raft'}), \
                patch.object(release.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 1, '{"status":"404"}', 'not found'),
                    subprocess.CompletedProcess([], 0, json.dumps([
                        [{'tag_name': 'v0.1.0+10', 'draft': True}], [draft]]), '')
                ]) as command:
            self.assertEqual(release.read_release('v0.1.0+1'), draft)
            self.assertIn('v0.1.0%2B1', command.call_args_list[0].args[0][-1])
            self.assertEqual(command.call_args_list[1].args[0],
                             ['gh', 'api', '--paginate', '--slurp',
                              'repos/owner/raft/releases?per_page=100'])

    def test_published_release_needs_no_list_fallback(self):
        remote = {'tag_name': 'v0.1.0+1', 'draft': False}
        with patch.dict(release.os.environ, {'GITHUB_REPOSITORY': 'owner/raft'}), \
                patch.object(release.subprocess, 'run', return_value=
                             subprocess.CompletedProcess([], 0, json.dumps(remote), '')) as command:
            self.assertEqual(release.read_release('v0.1.0+1'), remote)
            self.assertEqual(command.call_count, 1)

    def test_only_confirmed_404_is_absent_and_plus_tag_is_url_encoded(self):
        with patch.dict(release.os.environ, {'GITHUB_REPOSITORY': 'owner/raft'}):
            for status in [404, 403, 401, 500, None]:
                result = subprocess.CompletedProcess([], 1, json.dumps({'status': status}), 'failure')
                results = [result, subprocess.CompletedProcess([], 0, '[[], []]', '')]
                with patch.object(release.subprocess, 'run', side_effect=results) as command:
                    if status == 404:
                        self.assertIsNone(release.read_release('v0.1.0+1', missing_ok=True))
                    else:
                        with self.assertRaises(subprocess.CalledProcessError):
                            release.read_release('v0.1.0+1', missing_ok=True)
                    self.assertIn('v0.1.0%2B1', command.call_args_list[0].args[0][-1])
                    self.assertEqual(command.call_count, 2 if status == 404 else 1)
            with patch.object(release.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'network')):
                with self.assertRaises(subprocess.CalledProcessError):
                    release.read_release('v0.1.0+1', missing_ok=True)

    def test_list_permission_or_network_failure_is_not_absence(self):
        with patch.dict(release.os.environ, {'GITHUB_REPOSITORY': 'owner/raft'}):
            for status in [403, 401, 500, None]:
                with self.subTest(status=status), patch.object(release.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 1, '{"status":"404"}', 'not found'),
                    subprocess.CompletedProcess([], 1, json.dumps({'status': status}), 'failure')
                ]), self.assertRaises(subprocess.CalledProcessError):
                    release.read_release('v0.1.0+1', missing_ok=True)

    def test_missing_required_release_and_ambiguous_tag_fail_closed(self):
        with patch.dict(release.os.environ, {'GITHUB_REPOSITORY': 'owner/raft'}):
            for pages, error in [([[]], subprocess.CalledProcessError),
                                  ([[{'tag_name': 'v0.1.0+1'}],
                                    [{'tag_name': 'v0.1.0+1'}]], ValueError)]:
                with self.subTest(pages=pages), patch.object(release.subprocess, 'run', side_effect=[
                    subprocess.CompletedProcess([], 1, '{"status":"404"}', 'not found'),
                    subprocess.CompletedProcess([], 0, json.dumps(pages), '')
                ]), self.assertRaises(error):
                    release.read_release('v0.1.0+1')


if __name__ == '__main__':
    unittest.main()
