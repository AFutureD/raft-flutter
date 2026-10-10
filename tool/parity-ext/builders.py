"""Manifest builders for the parity extension suite.

`tool/parity-ext/run` generates the case manifest at run time instead of
committing it: every tool/parity-ext/build-*.py is executed in the order of
tool/parity-ext/builders.txt and writes to the path in $PARITY_EXT_MANIFEST.
Builders import `manifest_path()` from here instead of hard-coding a path.
"""
import os
import pathlib
import subprocess
import sys

EXT = pathlib.Path(__file__).resolve().parent


def manifest_path():
    """Where a builder reads/writes the manifest (set by the runner)."""
    value = os.environ.get('PARITY_EXT_MANIFEST')
    if not value:
        sys.exit('PARITY_EXT_MANIFEST is not set: builders run through `tool/parity-ext/run`, '
                 'which generates the manifest (it is no longer committed)')
    return pathlib.Path(value)


def registered(registry):
    lines = [l.split('#')[0].strip() for l in registry.read_text().splitlines()]
    return [l for l in lines if l]


def ordered_builders(ext=EXT):
    """-> (ordered build-*.py names, unregistered names, missing registered names).

    Registered builders keep the registry order; build-*.py files that are not
    listed follow, alphabetically."""
    registry = pathlib.Path(ext) / 'builders.txt'
    present = sorted(p.name for p in pathlib.Path(ext).glob('build-*.py'))
    listed = registered(registry) if registry.is_file() else []
    missing = [n for n in listed if n not in present]
    known = [n for n in listed if n in present]
    unknown = [n for n in present if n not in listed]
    return known + unknown, unknown, missing


def build_manifest(out, ext=EXT, env=None):
    """Run every builder; returns the manifest path (<out>/cases.json)."""
    ext, out = pathlib.Path(ext), pathlib.Path(out)
    out.mkdir(parents=True, exist_ok=True)
    target = out / 'cases.json'
    target.unlink(missing_ok=True)
    names, unknown, missing = ordered_builders(ext)
    for n in missing:
        print(f'builders: warning: {n} is listed in builders.txt but does not exist', file=sys.stderr)
    for n in unknown:
        print(f'builders: warning: {n} is not listed in tool/parity-ext/builders.txt; '
              'running it last (alphabetically). Add it to the registry to pin its order.', file=sys.stderr)
    run_env = {**os.environ, **(env or {}), 'PARITY_EXT_MANIFEST': str(target)}
    log = out / 'builders.log'
    with open(log, 'w') as sink:
        for name in names:
            r = subprocess.run([sys.executable, str(ext / name)], cwd=ext.parents[1], env=run_env,
                               stdout=sink, stderr=subprocess.STDOUT)
            if r.returncode != 0:
                sys.exit(f'builder {name} failed (exit {r.returncode}); see {log}')
    if not target.is_file():
        sys.exit(f'no builder wrote {target}; see {log}')
    return target
