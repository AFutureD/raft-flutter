#!/usr/bin/env python3
"""Read-only ADB collection/analysis for RAFT_ROUTE_FRAME_DIAGNOSTICS.

Does not build, install, launch, stop, navigate or clear any app. The running
app must have opted into the probe at build time. Stores only probe records.
"""
import argparse
from bisect import bisect_left
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

MARKER = 'RAFT_ROUTE_PERF '


def records(path):
    rows, malformed = [], 0
    for line in Path(path).read_text().splitlines():
        payload = line.split(MARKER, 1)[-1] if MARKER in line else line
        if MARKER not in line and not payload.startswith(('{', '[')):
            continue
        try:
            value = json.loads(payload)
            rows.extend(value if isinstance(value, list) else [value])
        except json.JSONDecodeError:
            # Recover complete leading objects from the early Android batch
            # format, but mark the collection incomplete. Never infer missing
            # records or accept truncated logs as a complete baseline.
            malformed += 1
            if payload.startswith('['):
                rest = payload[1:]
                while rest:
                    try:
                        value, end = json.JSONDecoder().raw_decode(rest)
                    except json.JSONDecodeError:
                        break
                    rows.append(value)
                    rest = rest[end:].lstrip(', ')
    return [r for r in rows if isinstance(r, dict)], malformed


def summarize(rows, malformed=0):
    ui = sorted((r for r in rows if r.get('kind') == 'ui'), key=lambda r: r['start'])
    starts = [r['start'] for r in ui]
    flushes = [r for r in rows if r.get('kind') == 'probeFlush']
    used, matched, affected = set(), [], 0
    for frame in (r for r in rows if r.get('kind') == 'frame'):
        i = bisect_left(starts, frame['buildStart'])
        options = [j for j in (i - 1, i) if 0 <= j < len(ui) and j not in used]
        if not options:
            continue
        j = min(options, key=lambda k: abs(starts[k] - frame['buildStart']))
        if abs(starts[j] - frame['buildStart']) > 2000:
            continue
        used.add(j)
        begin = min(ui[j]['start'], frame['vsync'])
        end = ui[j]['start'] + ui[j]['uiUs']
        if any(begin < f['end'] and end > f['start'] for f in flushes):
            affected += 1
            continue
        matched.append({**frame, **ui[j]})

    def costs(values):
        values = sorted(values)
        return {'p99Ms': round(values[min(len(values) - 1, int(len(values) * .99))] / 1000, 3),
                'maxMs': round(values[-1] / 1000, 3)} if values else None

    screens = {}
    for screen in sorted({r['screen'] for r in matched}):
        frames = [r for r in matched if r['screen'] == screen]
        screens[screen] = {
            'matchedFrames': len(frames),
            'ui': costs([r['uiUs'] for r in frames]),
            'engineBuild': costs([r['buildUs'] for r in frames]),
            'raster': costs([r['rasterUs'] for r in frames]),
            'slowestUiPhasesUs': max(frames, key=lambda r: r['uiUs'])['scopes'],
        }
    return {
        'scope': 'Observed matched frames; diagnostic collection, not a lab acceptance gate',
        'malformedLines': malformed,
        'droppedRecords': sum(f.get('dropped', 0) for f in flushes),
        'unmatchedUiRecords': len(ui) - len(used),
        'probeExportAffectedFrames': affected,
        'screens': screens,
    }


def capture(args):
    adb = ['adb', '-s', args.device]
    pid = subprocess.check_output(adb + ['shell', 'pidof', '-s', args.package], text=True).strip()
    if not pid.isdigit():
        raise RuntimeError('App is not running; launch it yourself before capture.')
    args.out.mkdir(parents=True, exist_ok=False)
    path = args.out / 'probe.jsonl'
    process = subprocess.Popen(adb + ['logcat', '--pid', pid, '-T', '1', '-v', 'raw', 'flutter:I', '*:S'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    poll = selectors.DefaultSelector()
    poll.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.seconds
    pending = b''
    print(f'Collecting the running {args.package} for {args.seconds}s; no device input is sent.', flush=True)
    try:
        with path.open('w') as output:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('ADB log stream ended before capture completed.')
                if not poll.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                    continue
                pending += os.read(process.stdout.fileno(), 65536)
                lines = pending.split(b'\n')
                pending = lines.pop()
                for raw in lines:
                    line = raw.decode(errors='replace')
                    if MARKER in line:
                        output.write(line.split(MARKER, 1)[1].strip() + '\n')
    finally:
        poll.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    current = subprocess.check_output(adb + ['shell', 'pidof', '-s', args.package], text=True).strip()
    if current != pid:
        raise RuntimeError('App process changed during capture; partial records were preserved.')
    rows, malformed = records(path)
    if not rows:
        raise RuntimeError('No probe records; verify RAFT_ROUTE_FRAME_DIAGNOSTICS=true in this build.')
    report = summarize(rows, malformed)
    (args.out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    take = sub.add_parser('capture')
    take.add_argument('--device', required=True)
    take.add_argument('--package', choices=['app.raft.raft_flutter', 'app.raft.raft_flutter.linkperf'],
                      default='app.raft.raft_flutter')
    take.add_argument('--seconds', type=int, default=60, choices=range(5, 61), metavar='5..60')
    take.add_argument('--out', required=True, type=Path)
    read = sub.add_parser('summarize')
    read.add_argument('log', type=Path)
    args = parser.parse_args()
    if args.command == 'capture':
        capture(args)
    else:
        rows, malformed = records(args.log)
        print(json.dumps(summarize(rows, malformed), indent=2))


if __name__ == '__main__':
    main()
