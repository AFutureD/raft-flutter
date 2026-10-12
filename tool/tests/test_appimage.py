import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('appimage', Path(__file__).resolve().parents[1] / 'appimage.py')
appimage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appimage)


class AppImageTests(unittest.TestCase):
    def test_dependency_parse_rejects_unresolved_libraries_and_version_failures(self):
        for text in ['libgtk-3.so.0 => not found', 'libc.so.6: version `GLIBC_2.40\' not found']:
            with patch.object(appimage, 'capture', return_value=text), self.assertRaises(ValueError):
                appimage.dependencies(Path('/app/raft'))

    def test_newer_glibc_payload_is_rejected_before_packaging(self):
        self.assertEqual(appimage.glibc_requirement('Name: GLIBC_2.38\nName: GLIBC_2.39'), (2, 39))
        with self.assertRaisesRegex(ValueError, 'exceeds'):
            appimage.glibc_requirement('Name: GLIBC_2.42')

    def test_tool_hash_drift_never_creates_a_cached_executable(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(appimage.urllib.request, 'urlopen',
                return_value=io.BytesIO(b'changed executable')):
            with self.assertRaisesRegex(ValueError, 'SHA-256'):
                appimage.download_tool('runtime', {'url': 'https://example.com/runtime', 'sha256': '0' * 64}, Path(folder))
            self.assertFalse(list(Path(folder).iterdir()))

    def test_verified_tool_cache_is_used_and_bad_cache_preserved(self):
        data = b'pinned executable'
        with tempfile.TemporaryDirectory() as folder, patch.object(appimage.urllib.request, 'urlopen') as request:
            path = Path(folder) / 'runtime'
            path.write_bytes(data)
            record = {'url': 'https://example.com/runtime', 'sha256': hashlib.sha256(data).hexdigest()}
            self.assertEqual(appimage.download_tool('runtime', record, Path(folder)), path)
            path.write_bytes(b'corrupted')
            with self.assertRaisesRegex(ValueError, 'cached'):
                appimage.download_tool('runtime', record, Path(folder))
            self.assertEqual(path.read_bytes(), b'corrupted')
            request.assert_not_called()


if __name__ == '__main__':
    unittest.main()
