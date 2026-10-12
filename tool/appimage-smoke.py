#!/usr/bin/env python3
"""Exercise the downloaded production AppImage in a disposable CI desktop."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time


def capture(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['direct', 'extract', 'wayland'], required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Production startup checks are limited to disposable CI environments')
    args.output.mkdir(parents=True, exist_ok=True)
    artifact = args.artifact.resolve()
    if args.mode != 'direct' and Path('/dev/fuse').exists():
        # Extract mode still never opens /dev/fuse; containers additionally prove
        # it works when the device itself does not exist.
        fuse_state = 'present; explicit extract-and-run'
    else:
        fuse_state = 'absent' if not Path('/dev/fuse').exists() else 'present'
    subprocess.run(['gnome-keyring-daemon', '--unlock', '--components=secrets'],
                   input='', text=True, capture_output=True, check=True)
    with tempfile.TemporaryDirectory(prefix='raft-appimage-ci-') as temporary:
        env = dict(os.environ, GDK_SCALE='2', GDK_DPI_SCALE='1',
                   XDG_DATA_HOME=str(Path(temporary) / 'data'),
                   XDG_CONFIG_HOME=str(Path(temporary) / 'config'),
                   XDG_CACHE_HOME=str(Path(temporary) / 'cache'))
        command = [str(artifact)]
        if args.mode != 'direct':
            command.append('--appimage-extract-and-run')
        if args.mode == 'wayland':
            env.update(GDK_BACKEND='wayland', WAYLAND_DEBUG='1')
        logfile = args.output / f'{args.mode}-launch.log'
        with logfile.open('w') as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                deadline = time.monotonic() + 40
                window = None
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise ValueError(f'AppImage exited before painting: {process.returncode}')
                    if args.mode == 'wayland':
                        log.flush()
                        text = logfile.read_text()
                        if re.search(r'wl_surface[^\n]*\.attach\(wl_buffer', text) and \
                                re.search(r'wl_surface[^\n]*\.commit\(', text):
                            window = 'native Wayland attached and committed buffer'
                    else:
                        matches = re.findall(r'(0x[0-9a-f]+) "Raft"', capture(['xwininfo', '-root', '-tree']))
                        if matches:
                            window = matches[0]
                    if window:
                        break
                    time.sleep(0.25)
                if window is None:
                    raise ValueError('No production Raft window/frame appeared')
                time.sleep(5)
                if process.poll() is not None:
                    raise ValueError('AppImage exited after creating the window')
                log.flush()
                text = logfile.read_text()
                if 'libsecret_error:' in text or 'error while loading shared libraries:' in text:
                    raise ValueError('AppImage startup contains a missing library or secure-storage failure')
                result = {'artifact': artifact.name, 'mode': args.mode, 'fuseDevice': fuse_state,
                          'window': window, 'GDK_SCALE': 2, 'GDK_DPI_SCALE': 1,
                          'osRelease': Path('/etc/os-release').read_text(),
                          'scope': 'production first screen; no account or messaging acceptance',
                          'softwareRenderingForced': env.get('LIBGL_ALWAYS_SOFTWARE') == '1'}
                if args.mode != 'wayland':
                    png = args.output / f'raft-linux-appimage-{args.mode}-hidpi.png'
                    subprocess.run(['import', '-window', window, png], check=True)
                    width, height, colors = map(int, capture(['identify', '-format', '%w %h %k', png]).split())
                    if width < 1000 or height < 600 or colors < 32:
                        raise ValueError('Screenshot lacks a full painted HiDPI window')
                    result.update(file=png.name, width=width, height=height, colors=colors)
                (args.output / f'{args.mode}.json').write_text(json.dumps(result, indent=2) + '\n')
            finally:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)


if __name__ == '__main__':
    main()
