#!/usr/bin/env python3
"""Start the installed production Flatpak in a disposable CI desktop; capture 2x PNG."""
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'app.raft.raft_flutter'


def capture(args):
    return subprocess.check_output(args, text=True)


def main():
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('Smoke installation is limited to the disposable GitHub runner')
    # A normal Linux desktop supplies Secret Service. Provide a fresh unlocked
    # keyring in this disposable session; never use or copy a user's profile.
    subprocess.run(['gnome-keyring-daemon', '--unlock', '--components=secrets'],
                   input='', text=True, capture_output=True, check=True)
    artifacts = list((ROOT / 'build/release').glob('*.flatpak'))
    if len(artifacts) != 1:
        raise ValueError('Expected exactly one Flatpak bundle')
    existing = subprocess.run(['flatpak', 'info', '--user', APP_ID], capture_output=True)
    if existing.returncode == 0:
        raise ValueError('Refusing to replace an existing installed Raft')
    subprocess.run(['flatpak', 'install', '--user', '--noninteractive', artifacts[0]], check=True)
    info = capture(['flatpak', 'info', '--user', APP_ID])
    if 'org.gnome.Platform/x86_64/51' not in info:
        raise ValueError('Installed runtime differs from the package contract')
    out = ROOT / 'build/flatpak-smoke'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'installed.txt').write_text(info)
    with (out / 'launch.log').open('w') as log:
        process = subprocess.Popen(['flatpak', 'run', '--user', '--env=GDK_SCALE=2',
            '--env=GDK_DPI_SCALE=1', '--env=LIBGL_ALWAYS_SOFTWARE=1', APP_ID],
            stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            window = None
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise ValueError(f'Flatpak exited before showing a window: {process.returncode}')
                tree = capture(['xwininfo', '-root', '-tree'])
                matches = re.findall(r'(0x[0-9a-f]+) "Raft"', tree)
                if matches:
                    window = matches[0]
                    break
                time.sleep(0.25)
            if window is None:
                raise ValueError('No Raft GTK window appeared within 30 seconds')
            # Let the first production Flutter frame paint after native window creation.
            time.sleep(5)
            if process.poll() is not None:
                raise ValueError('Flatpak exited after creating its window')
            log.flush()
            if 'libsecret_error:' in (out / 'launch.log').read_text():
                raise ValueError('Secure storage is unavailable in the smoke desktop')
            png = out / 'raft-linux-flatpak-hidpi.png'
            subprocess.run(['import', '-window', window, png], check=True)
            dimensions = capture(['identify', '-format', '%w %h %k', png]).split()
            width, height, colors = map(int, dimensions)
            if width < 1000 or height < 600 or colors < 32:
                raise ValueError('Screenshot is too small or lacks painted content')
            (out / 'screenshot.json').write_text(json.dumps({
                'appId': APP_ID, 'sourceCommit': capture(['git', 'rev-parse', 'HEAD']).strip(),
                'GDK_SCALE': 2, 'GDK_DPI_SCALE': 1, 'width': width, 'height': height,
                'colors': colors, 'file': png.name,
                'scope': 'production entry point, fresh sandbox, first screen; no login or messaging acceptance'}, indent=2) + '\n')
        finally:
            subprocess.run(['flatpak', 'kill', APP_ID], check=False)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
