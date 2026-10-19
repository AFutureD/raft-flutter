import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
SPEC = importlib.util.spec_from_file_location('test_budget', TOOL / 'test_budget.py')
budget = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(budget)

BASELINE = {'version': 1, 'files': {'apps/raft_flutter/test/big_test.dart': {'cases': 100, 'seconds': 80.0}}}


def entry(cases, seconds, load=1.0):
    return {'tests': cases, 'seconds': seconds + load, 'loadSeconds': load}


class MeasureTests(unittest.TestCase):
    def test_run_seconds_exclude_the_load(self):
        measured = budget.measure({'a_test.dart': entry(7, 12.0, load=3.0), 'empty_test.dart': {'tests': 0, 'seconds': 1.0, 'loadSeconds': 1.0}})
        self.assertEqual(measured, {'a_test.dart': {'cases': 7, 'seconds': 12.0}})


class CheckTests(unittest.TestCase):
    def verdict(self, measured, exempt=False, baseline=BASELINE, exists=True):
        return budget.check(measured, baseline, lambda name: exempt, lambda name: exists)

    def test_a_small_new_file_passes(self):
        self.assertEqual(self.verdict({'new_test.dart': {'cases': 60, 'seconds': 30.0}})['violations'], [])

    def test_a_new_file_over_the_case_limit_fails_unless_exempt(self):
        now = {'cases': 61, 'seconds': 2.0}
        result = self.verdict({'new_test.dart': now})
        self.assertEqual(len(result['violations']), 1)
        self.assertIn('nightly-full', result['violations'][0])
        self.assertEqual(self.verdict({'new_test.dart': now}, exempt=True)['violations'], [])

    def test_seconds_only_warn_because_gate_timings_depend_on_the_other_shards(self):
        result = self.verdict({'new_test.dart': {'cases': 3, 'seconds': 31.0}})
        self.assertEqual((result['violations'], len(result['warnings'])), ([], 1))
        self.assertEqual(self.verdict({'new_test.dart': {'cases': 3, 'seconds': 31.0}}, exempt=True)['warnings'], [])

    def test_a_listed_file_may_not_gain_cases_and_running_much_longer_warns(self):
        name = 'apps/raft_flutter/test/big_test.dart'
        self.assertEqual(self.verdict({name: {'cases': 100, 'seconds': 80.0}})['violations'], [])
        self.assertEqual(self.verdict({name: {'cases': 90, 'seconds': 120.0}})['warnings'], [])  # noise inside 1.5x + 10 s
        self.assertIn('grew from 100 to 101', self.verdict({name: {'cases': 101, 'seconds': 80.0}})['violations'][0])
        slower = self.verdict({name: {'cases': 100, 'seconds': 131.0}})
        self.assertEqual((slower['violations'], len(slower['warnings'])), ([], 1))

    def test_stale_entries_are_notes_never_failures(self):
        name = 'apps/raft_flutter/test/big_test.dart'
        gone = self.verdict({}, exists=False)
        self.assertEqual((gone['violations'], len(gone['notes'])), ([], 1))
        tagged = self.verdict({name: {'cases': 100, 'seconds': 80.0}}, exempt=True)
        self.assertEqual((tagged['violations'], len(tagged['notes'])), ([], 1))
        small = self.verdict({name: {'cases': 10, 'seconds': 5.0}})
        self.assertEqual((small['violations'], len(small['notes'])), ([], 1))


class LoweredTests(unittest.TestCase):
    def test_entries_shrink_or_go_and_none_is_added(self):
        baseline = {'version': 1, 'files': {
            'a_test.dart': {'cases': 100, 'seconds': 80.0}, 'b_test.dart': {'cases': 90, 'seconds': 70.0},
            'c_test.dart': {'cases': 80, 'seconds': 60.0}, 'd_test.dart': {'cases': 70, 'seconds': 50.0}}}
        measured = {'a_test.dart': {'cases': 90, 'seconds': 95.0},  # fewer cases, slower
                    'b_test.dart': {'cases': 10, 'seconds': 3.0},   # under the limits: entry goes
                    'new_test.dart': {'cases': 500, 'seconds': 500.0}}  # never added
        result = budget.lowered(baseline, measured, lambda name: name == 'c_test.dart', lambda name: name != 'd_test.dart')
        self.assertEqual(result['files'], {'a_test.dart': {'cases': 90, 'seconds': 80.0}})


class ExemptionTests(unittest.TestCase):
    def test_slow_tag_in_the_head_or_the_marker_anywhere(self):
        with tempfile.TemporaryDirectory() as tmp:
            def write(name, text):
                path = Path(tmp) / name
                path.write_text(text)
                return path
            self.assertTrue(budget.is_exempt(write('a.dart', "@Tags(['slow'])\nlibrary;\nimport 'x';\n")))
            self.assertTrue(budget.is_exempt(write('b.dart', "import 'x';\nvoid main() {\n  // matrix: nightly-full -- the gate runs the L\n}\n")))
            self.assertFalse(budget.is_exempt(write('c.dart', "import 'x';\n// we discuss matrix: nightly-full here\n")))
            self.assertFalse(budget.is_exempt(write('d.dart', "@Tags(['golden'])\nlibrary;\n")))
            self.assertFalse(budget.is_exempt(Path(tmp) / 'missing.dart'))


class BootstrapTests(unittest.TestCase):
    def test_only_over_limit_non_exempt_files_are_listed_and_a_second_bootstrap_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases = Path(tmp) / 'cases.json'
            cases.write_text(json.dumps({'big_test.dart': {'cases': 99, 'seconds': 10.0}, 'small_test.dart': {'cases': 5, 'seconds': 2.0}}))
            target = Path(tmp) / 'baseline.json'
            self.assertEqual(budget.main(['--bootstrap', str(cases), '--baseline', str(target)]), 0)
            self.assertEqual(list(json.loads(target.read_text())['files']), ['big_test.dart'])
            with self.assertRaises(SystemExit):
                budget.main(['--bootstrap', str(cases), '--baseline', str(target)])


if __name__ == '__main__':
    unittest.main()
