import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('route_probe', Path(__file__).with_name('route_probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class RouteProbeTest(unittest.TestCase):
    def test_matches_full_ui_cycle_separately_from_engine_build_and_raster(self):
        rows = [
            {'kind': 'ui', 'start': 10000, 'uiUs': 12000, 'screen': 'computer', 'scopes': {'semanticsUs': 8000}},
            {'kind': 'frame', 'buildStart': 10020, 'buildUs': 1000, 'rasterUs': 42000, 'vsync': 9990},
        ]
        report = probe.summarize(rows)
        screen = report['screens']['computer']
        self.assertEqual(screen['ui']['maxMs'], 12)
        self.assertEqual(screen['engineBuild']['maxMs'], 1)
        self.assertEqual(screen['raster']['maxMs'], 42)
        self.assertEqual(screen['slowestUiPhasesUs']['semanticsUs'], 8000)

    def test_excludes_export_overlap_and_reports_dropped_records(self):
        rows = [
            {'kind': 'ui', 'start': 10000, 'uiUs': 12000, 'screen': 'home', 'scopes': {}},
            {'kind': 'frame', 'buildStart': 10020, 'buildUs': 1000, 'rasterUs': 1000, 'vsync': 9900},
            {'kind': 'probeFlush', 'start': 9000, 'end': 10100, 'dropped': 12},
        ]
        report = probe.summarize(rows)
        self.assertEqual(report['screens'], {})
        self.assertEqual(report['probeExportAffectedFrames'], 1)
        self.assertEqual(report['droppedRecords'], 12)

    def test_truncated_android_batch_is_recovered_but_never_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'log.txt'
            path.write_text('I/flutter: RAFT_ROUTE_PERF [{"kind":"route","screen":"home"},{"kind":"ui"\n')
            rows, malformed = probe.records(path)
        self.assertEqual(rows, [{'kind': 'route', 'screen': 'home'}])
        self.assertEqual(malformed, 1)

    def test_does_not_reuse_a_ui_record_for_another_engine_frame(self):
        rows = [
            {'kind': 'ui', 'start': 10000, 'uiUs': 2000, 'screen': 'home', 'scopes': {}},
            *[{'kind': 'frame', 'buildStart': 10020, 'buildUs': 1000, 'rasterUs': 1000, 'vsync': 9900} for _ in range(2)],
        ]
        self.assertEqual(probe.summarize(rows)['screens']['home']['matchedFrames'], 1)


if __name__ == '__main__':
    unittest.main()
