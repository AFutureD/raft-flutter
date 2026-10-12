import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('appimage', Path(__file__).resolve().parents[1] / 'appimage.py')
appimage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appimage)


class AppImageTests(unittest.TestCase):
    def run_external_launch(self, original, override=False):
        with tempfile.TemporaryDirectory(prefix='raft appimage launch ') as temporary:
            folder = Path(temporary)
            helper = folder / 'gio-launch-desktop'
            helper.write_text('#!/bin/sh\nexec "$@"\n')
            helper.chmod(0o755)
            if override:
                custom = folder / 'custom host launcher'
                custom.write_text('#!/bin/sh\nexport TEST_HOST_HELPER=yes\nexec "$@"\n')
                custom.chmod(0o755)
                original['GIO_LAUNCH_DESKTOP'] = str(custom)
            wrapper = folder / 'raft-gio-launch-desktop'
            wrapper.write_text(appimage.desktop_launcher_wrapper())
            wrapper.chmod(0o755)
            launch = folder / 'AppRun'
            launch.write_text('#!/bin/sh\nset -eu\n' + appimage.host_environment_capture() +
                'export PATH="/appimage/bin:$PATH"\n' +
                'export LD_LIBRARY_PATH="/appimage/lib"\n' +
                'export GIO_MODULE_DIR="/appimage/gio/modules"\n' +
                'export GSETTINGS_SCHEMA_DIR="/appimage/schemas"\n' +
                'export GIO_LAUNCH_DESKTOP="/appimage/launcher"\n' +
                'export GTK_IM_MODULE_FILE="/appimage/immodules.cache"\n' +
                'export GDK_PIXBUF_MODULE_FILE="/appimage/loaders.cache"\n' +
                'export APPDIR="/appimage" APPIMAGE="/appimage/file.AppImage" ARGV0="fake" OWD="/old"\n' +
                'exec "$@"\n')
            launch.chmod(0o755)
            probe = ('import os,json; print(json.dumps({k:v for k,v in os.environ.items() '
                     'if k in ["PATH","LD_LIBRARY_PATH","GIO_MODULE_DIR",'
                     '"GSETTINGS_SCHEMA_DIR","GIO_LAUNCH_DESKTOP","GTK_IM_MODULE_FILE","GDK_PIXBUF_MODULE_FILE","APPDIR","APPIMAGE","ARGV0","OWD","TEST_HOST_HELPER"] '
                     'or k.startswith("RAFT_APPIMAGE_HOST_")}))')
            result = subprocess.run([str(launch), str(wrapper), sys.executable, '-c', probe],
                                    env=original, text=True, capture_output=True, check=True)
            expected = dict(original)
            if override:
                expected['TEST_HOST_HELPER'] = 'yes'
            self.assertEqual(json.loads(result.stdout), expected)

    def test_external_desktop_apps_recover_host_variables_and_unset_state(self):
        for state in ('unset', 'empty', 'set'):
            with self.subTest(state=state):
                original = {'PATH': os.defpath}
                for key in ('LD_LIBRARY_PATH', 'GIO_MODULE_DIR', 'GSETTINGS_SCHEMA_DIR', 'GTK_IM_MODULE_FILE', 'GDK_PIXBUF_MODULE_FILE'):
                    if state != 'unset':
                        original[key] = '' if state == 'empty' else '/host path/' + key
                self.run_external_launch(original)

    def test_explicit_host_launcher_override_is_used_after_environment_restore(self):
        self.run_external_launch({'PATH': os.defpath, 'GIO_MODULE_DIR': '/host/modules'},
                                 override=True)

    def test_host_input_method_cache_is_discovered_without_overwriting_user_selection(self):
        with tempfile.TemporaryDirectory(prefix='raft im cache ') as temporary:
            cache = Path(temporary) / 'immodules.cache'
            cache.write_text('fixture module cache')
            script = appimage.input_method_cache_setup(['/missing/cache', str(cache)])
            command = script + 'exec ' + appimage.shlex.quote(sys.executable) + \
                ' -c \'import os; print(os.environ.get("GTK_IM_MODULE_FILE", "<unset>"))\'\n'
            for configured in (None, '', '/chosen/user/cache'):
                with self.subTest(configured=configured):
                    env = {'PATH': os.defpath}
                    if configured is not None:
                        env['GTK_IM_MODULE_FILE'] = configured
                    result = subprocess.run(['/bin/sh', '-c', command], env=env,
                                            text=True, capture_output=True, check=True)
                    self.assertEqual(result.stdout.rstrip('\n'),
                                     str(cache) if configured is None else configured)

    def test_image_loader_cache_relocates_matching_modules_and_rejects_missing_entries(self):
        modules = [Path('/build path/libpixbufloader-svg.so')]
        text = '# LoaderDir = /build path\n"/build path/libpixbufloader-svg.so"\n"svg" 6 "gdk-pixbuf"\n'
        self.assertEqual(appimage.image_loader_cache(text, modules),
                         '"libpixbufloader-svg.so"\n"svg" 6 "gdk-pixbuf"\n')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            appimage.image_loader_cache('', modules)

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
