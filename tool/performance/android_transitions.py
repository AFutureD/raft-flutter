#!/usr/bin/env python3
"""Build the isolated profile app and measure Android page transitions.

    python3 tool/performance/android_transitions.py --device 10.77.0.24:38213 \
        --out .local/performance/android-transitions/before

Builds `integration_test/perf_lab_test.dart` as an ARM64 profile APK whose
application id is `app.raft.raft_flutter.linkperf` (Gradle property
`raftApplicationIdSuffix`; the real `app.raft.raft_flutter` is never built,
installed, replaced, cleared or uninstalled) and runs every `nav-*` scenario
through `tool/performance/lab.py`, which verifies the package identity and that
the real App's install time and data directories are unchanged. Works on
macOS and Linux; needs only `adb` access to the device.

Output (`<out>/run/`): one `<theme>-<scenario>.json` of raw per-frame timings
and `*.attribution.json` of CPU/timeline samples per scenario, `summary.md`,
`env.json`, `runner.log`. `<out>/run.tar.gz` bundles them for sharing.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/raft_flutter'
ABIS = {'arm64': 'android-arm64', 'x64': 'android-x64'}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--device', required=True, help='adb serial, e.g. 10.77.0.24:38213 (adb connect first)')
    p.add_argument('--out', required=True, type=Path, help='new directory for APK and run data')
    p.add_argument('--themes', default='brutal-light,elegant-light')
    p.add_argument('--scenarios', default='nav-*', help='comma list of nav-* scenarios (default all)')
    p.add_argument('--abi', choices=ABIS, default='arm64', help='x64 only for functional checks on an x86_64 emulator')
    p.add_argument('--semantics', default='platform', choices=['platform', 'on', 'off'])
    p.add_argument('--apk', type=Path, help='reuse a prebuilt isolated test APK instead of building')
    p.add_argument('--define', action='append', default=[], metavar='KEY=VALUE',
                   help='extra --dart-define for the build (repeatable)')
    p.add_argument('--allow-noisy', action='store_true', help='measure even if host load is high (results labelled NOISY)')
    args = p.parse_args()
    out = args.out.resolve()
    if out.exists():
        p.error(f'{out} exists; use a new directory so earlier data stays unchanged')
    out.mkdir(parents=True)
    apk = args.apk.resolve() if args.apk else out / 'apk' / 'perf-lab-linkperf.apk'
    if not args.apk:
        apk.parent.mkdir()
        build = [str(ROOT / 'tool/flutter'), 'build', 'apk', '--profile', '--target-platform', ABIS[args.abi],
                 '-t', 'integration_test/perf_lab_test.dart', '--no-pub',
                 '--android-project-arg=raftApplicationIdSuffix=.linkperf',
                 f'--dart-define=RAFT_LAB_THEMES={args.themes}', f'--dart-define=RAFT_LAB_SCENARIOS={args.scenarios}',
                 f'--dart-define=RAFT_LAB_SEMANTICS={args.semantics}',
                 *[f'--dart-define={d}' for d in args.define]]
        print('Building:', ' '.join(build), flush=True)
        if subprocess.run(build, cwd=APP).returncode:
            sys.exit('Profile build failed.')
        shutil.copyfile(APP / 'build/app/outputs/flutter-apk/app-profile.apk', apk)
    run = [sys.executable, str(ROOT / 'tool/performance/lab.py'), 'run', '--device', args.device,
           '--out', str(out / 'run'), '--themes', args.themes, '--scenarios', args.scenarios, '--semantics', args.semantics,
           '--wait-quiet', '0']
    if args.allow_noisy:
        run.append('--allow-noisy')
    run += ['--', f'--use-application-binary={apk}']
    print('Running:', ' '.join(run), flush=True)
    status = subprocess.run(run, cwd=ROOT).returncode
    if (out / 'run').is_dir():
        shutil.make_archive(str(out / 'run'), 'gztar', out, 'run')
        print(f'Raw data: {out / "run"} (archive {out / "run.tar.gz"})')
    return status


if __name__ == '__main__':
    raise SystemExit(main())
