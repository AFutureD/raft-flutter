#!/usr/bin/env python3
"""Read-only Android capture companion for the isolated section perf fixture.

Start before lab.py, using the same new --run directory. The fixture emits
capture notes and keeps all screen recording outside measured intervals.
This tool does not install, launch, navigate or send device input.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--run', type=Path, required=True)
    args = parser.parse_args()
    adb = ['adb', '-s', args.device]
    seen, recorders = set(), []
    deadline = time.monotonic() + 600
    if (args.run / 'driver-result.json').exists():
        raise RuntimeError('Run already completed; use a new run directory.')
    while time.monotonic() < deadline:
        notes = args.run / 'lab-notes.jsonl'
        lines = notes.read_text().splitlines() if notes.exists() else []
        for line in lines:
            try:
                note = json.loads(line)
            except json.JSONDecodeError:
                continue  # writer may still be appending the final note
            if not note.get('capture') or note['token'] in seen:
                continue
            seen.add(note['token'])
            theme, label = note['theme'], note['capture']
            if not all(re.fullmatch(r'[a-z0-9-]+', v) for v in (theme, label)):
                raise ValueError('Invalid capture label')
            activity = subprocess.check_output(
                adb + ['shell', 'dumpsys', 'activity', 'activities'], text=True)
            if not re.search(r'(?:mResumedActivity:|topResumedActivity=).*app\.raft\.raft_flutter\.linkperf/', activity):
                raise RuntimeError('Isolated fixture is not the resumed activity; capture stopped.')
            if label == 'video-start':
                seconds = int(note['videoSeconds'])
                if not 1 <= seconds <= 30:
                    raise ValueError('Invalid video duration')
                remote = f'/sdcard/raft-section-{uuid.uuid4().hex}.mp4'
                process = subprocess.Popen(adb + ['shell', 'screenrecord',
                    '--time-limit', str(seconds), '--bit-rate', '12000000', remote])
                recorders.append((process, remote, theme))
                continue
            image = args.run / f'{theme}-{label}.png'
            with image.open('wb') as output:
                subprocess.run(adb + ['exec-out', 'screencap', '-p'],
                    stdout=output, check=True, timeout=15)
            image.with_suffix('.capture.json').write_text(json.dumps(note, indent=2))
        if (args.run / 'driver-result.json').exists():
            break
        time.sleep(.1)
    else:
        raise TimeoutError('Fixture did not complete within 10 minutes')
    for process, remote, theme in recorders:
        if process.wait(timeout=40) != 0:
            raise RuntimeError(f'Recording failed for {theme}')
        subprocess.run(adb + ['pull', remote, str(args.run / f'{theme}-return.mp4')],
            check=True, timeout=90)


if __name__ == '__main__':
    main()
