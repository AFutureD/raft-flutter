import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

PATH = Path(__file__).resolve().parents[1] / 'check-project'
LOADER = importlib.machinery.SourceFileLoader('check_project', str(PATH))
SPEC = importlib.util.spec_from_loader('check_project', LOADER)
check = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(check)


def events(*items):
    return [json.dumps(item) for item in items]


SUITE = {'type': 'suite', 'suite': {'id': 1, 'platform': 'vm', 'path': '/repo/apps/raft_flutter/test/a_test.dart'}, 'time': 0}


def started(test_id, name, time, suite=1):
    return {'type': 'testStart', 'test': {'id': test_id, 'name': name, 'suiteID': suite}, 'time': time}


def done(test_id, time, result='success', skipped=False, hidden=False):
    return {'type': 'testDone', 'testID': test_id, 'result': result, 'skipped': skipped, 'hidden': hidden, 'time': time}


class PartitionTests(unittest.TestCase):
    def test_balances_by_weight_and_keeps_every_file_once(self):
        weights = {'a': 100, 'b': 60, 'c': 50, 'd': 40, 'e': 10}
        plan = check.partition(list(weights), weights, 2)
        self.assertEqual(sorted(sum((p['files'] for p in plan), [])), sorted(weights))
        self.assertLessEqual(max(p['weight'] for p in plan), 140)  # optimum 130

    def test_is_deterministic(self):
        weights = {f'f{i}': 1 + i % 7 for i in range(40)}
        self.assertEqual(check.partition(list(weights), weights, 4), check.partition(list(reversed(list(weights))), weights, 4))

    def test_unknown_files_get_a_share_by_size_not_zero(self):
        weights = {'known': 10}
        plan = check.partition(['known', 'new_big', 'new_small'], weights, 2, {'known': 100, 'new_big': 1000, 'new_small': 10})
        bins = {tuple(p['files']): p['weight'] for p in plan}
        self.assertIn(('new_big',), bins)
        self.assertEqual(bins[('new_big',)], 100.0)

    def test_without_history_everything_is_equal(self):
        plan = check.partition([f'f{i}' for i in range(10)], {}, 5)
        self.assertEqual([len(p['files']) for p in plan], [2] * 5)

    def test_never_more_shards_than_files(self):
        self.assertEqual(len(check.partition(['a', 'b'], {}, 8)), 2)
        self.assertEqual(check.partition([], {}, 4), [{'files': [], 'weight': 0.0}])


class ParallelismTests(unittest.TestCase):
    def test_default_scales_with_cpus_and_load(self):
        self.assertEqual(check.plan_parallelism(16, 0.0, {}), (5, 3))
        self.assertEqual(check.plan_parallelism(16, 10.0, {}), (2, 3))
        self.assertEqual(check.plan_parallelism(2, 8.0, {}), (1, 2))
        self.assertLessEqual(check.plan_parallelism(128, 0.0, {})[0], 8)

    def test_environment_overrides(self):
        self.assertEqual(check.plan_parallelism(16, 0.0, {'RAFT_CHECK_SHARDS': '3', 'RAFT_CHECK_JOBS': '1'}), (3, 1))

    def test_rejects_invalid_override(self):
        for bad in ('0', 'x', '-1'):
            with self.assertRaises(SystemExit):
                check.plan_parallelism(16, 0.0, {'RAFT_CHECK_SHARDS': bad})


class EventTests(unittest.TestCase):
    def parse(self, *items):
        return check.parse_test_events(events(*items), lambda p: p.replace('/repo/', ''))

    def test_passed_failed_skipped_and_durations(self):
        results = self.parse(
            SUITE,
            started(1, 'loading /repo/apps/raft_flutter/test/a_test.dart', 0), done(1, 4000, hidden=True),
            started(2, 'ok', 4000), done(2, 4500),
            started(3, 'bad', 4500), {'type': 'error', 'testID': 3, 'error': 'Expected: 1\n  Actual: 2', 'stackTrace': '', 'isFailure': True, 'time': 5000},
            done(3, 6500, result='failure'),
            started(4, 'skip me', 6500), done(4, 6500, skipped=True))
        summary = check.summarize_shard(results)
        self.assertEqual((summary['passed'], summary['skipped']), (1, 1))
        self.assertEqual([f['name'] for f in summary['failed']], ['bad'])
        self.assertEqual(summary['failed'][0]['error'], 'Expected: 1')
        self.assertEqual(summary['failed'][0]['file'], 'apps/raft_flutter/test/a_test.dart')
        files = check.file_durations(results, shard=2)
        self.assertEqual(files['apps/raft_flutter/test/a_test.dart'], {'seconds': 6.5, 'loadSeconds': 4.0, 'tests': 3, 'shard': 2})

    def test_load_failure_and_timeout_are_failures(self):
        results = self.parse(SUITE, started(1, 'loading /repo/x', 0), {'type': 'error', 'testID': 1, 'error': 'Compilation failed', 'stackTrace': '', 'isFailure': False, 'time': 10},
                             done(1, 20, result='error', hidden=True),
                             started(2, 'hangs', 30), {'type': 'error', 'testID': 2, 'error': 'TimeoutException after 0:01:00: Test timed out after 60 seconds.', 'stackTrace': '', 'isFailure': False, 'time': 60030},
                             done(2, 60030, result='error'))
        failed = check.summarize_shard(results)['failed']
        self.assertEqual([f['name'] for f in failed], ['loading /repo/x', 'hangs'])
        self.assertIn('timed out after 60 seconds', failed[1]['error'])

    def test_truncated_stream_reports_incomplete_test(self):
        lines = events(SUITE, started(1, 'killed mid-test', 100)) + ['{"type":"testDo']
        results = check.parse_test_events(lines)
        self.assertEqual([r['status'] for r in results], ['incomplete'])
        self.assertEqual(len(check.summarize_shard(results)['failed']), 1)

    def test_slowest_tests_are_sorted_capped_and_exclude_loading(self):
        items = [SUITE, started(1, 'loading /repo/x', 0), done(1, 99000, hidden=True)]
        for i in range(2, 32):
            items += [started(i, f't{i}', 0), done(i, i * 100)]
        slow = check.slowest_tests(self.parse(*items))
        self.assertEqual(len(slow), 20)
        self.assertEqual(slow[0]['name'], 't31')
        self.assertEqual([s['seconds'] for s in slow], sorted((s['seconds'] for s in slow), reverse=True))
        self.assertFalse(any(s['name'].startswith('loading') for s in slow))


class PassGateTests(unittest.TestCase):
    def test_marker_is_required(self):
        self.assertTrue(check.has_pass_marker('00:01 +3: foo\n00:02 +4 ~1: All tests passed!\n'))
        self.assertFalse(check.has_pass_marker('00:01 +652: slow test\n'))
        self.assertFalse(check.has_pass_marker('00:01 +4 -1: Some tests failed.\n'))
        self.assertFalse(check.has_pass_marker(''))

    def test_marker_must_be_at_the_end_not_in_test_output(self):
        log = 'All tests passed!\n' + '\n'.join(f'00:0{i} +{i}: next' for i in range(9))
        self.assertFalse(check.has_pass_marker(log))

    def test_files_that_never_ran_are_found(self):
        results = [{'file': 'apps/raft_flutter/test/a_test.dart'}, {'file': ''}]
        self.assertEqual(check.unfinished_files(['apps/raft_flutter/test/a_test.dart', 'apps/raft_flutter/test/b_test.dart'], results),
                         ['apps/raft_flutter/test/b_test.dart'])

    def test_repo_path_maps_app_relative_package_paths(self):
        self.assertEqual(check.repo_path('test/a_test.dart'), 'apps/raft_flutter/test/a_test.dart')
        self.assertEqual(check.repo_path('../../packages/raft_ui/test/c_test.dart'), 'packages/raft_ui/test/c_test.dart')


class SummaryTests(unittest.TestCase):
    def test_lists_failed_test_names_and_slowest(self):
        shards = [{'index': 0, 'passed': False, 'seconds': 61.2, 'files': ['a'], 'log': 'test-shard-0.txt'}]
        failures = [{'name': 'group hangs', 'file': 'apps/raft_flutter/test/a_test.dart', 'status': 'failed', 'error': 'Test timed out after 60 seconds.', 'shard': 0},
                    {'name': 'cut off', 'file': 'apps/raft_flutter/test/b_test.dart', 'status': 'incomplete', 'error': '', 'shard': 0}]
        text = check.format_summary(shards, failures, {'passed': 9, 'skipped': 1}, [{'name': 'slow one', 'file': 'f', 'seconds': 12.3}])
        self.assertIn('9 passed, 1 skipped, 2 failed across 1 shard(s)', text)
        self.assertIn('[0] apps/raft_flutter/test/a_test.dart: group hangs -- Test timed out after 60 seconds.', text)
        self.assertIn('cut off -- did not finish', text)
        self.assertIn('12.3s  f: slow one', text)

    def test_limit_truncates_the_listing_not_the_count(self):
        failures = [{'name': f't{i}', 'file': 'f', 'status': 'failed', 'error': 'e', 'shard': 0} for i in range(5)]
        text = check.format_summary([], failures, {'passed': 0, 'skipped': 0}, [], limit=2)
        self.assertIn('5 failed', text)
        self.assertIn('f: t1', text)
        self.assertNotIn('f: t2', text)
        self.assertIn('and 3 more', text)

    def test_history_weights_read_previous_run(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / '.local').mkdir()
            (repo / '.local/check-durations.json').write_text(json.dumps({'files': {'a': {'seconds': 3.5}, 'b': {'seconds': 0}}}))
            self.assertEqual(check.history_weights(repo), {'a': 3.5})
            self.assertEqual(check.history_weights(repo / 'missing'), {})


class DiscoveryTests(unittest.TestCase):
    def test_finds_app_and_package_tests_relative_to_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ['apps/raft_flutter/test/a_test.dart', 'apps/raft_flutter/test/parity/b_test.dart', 'apps/raft_flutter/test/helper.dart', 'packages/raft_ui/test/c_test.dart']:
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_text('')
            self.assertEqual(check.discover_tests(base), ['test/a_test.dart', 'test/parity/b_test.dart', '../../packages/raft_ui/test/c_test.dart'])


if __name__ == '__main__':
    unittest.main()
