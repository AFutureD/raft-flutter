"""Content-addressed cache of the Web (React) parity captures, shared by every
raft-flutter worktree: <cache>/react/<key>.png (+ .metadata.json, .key.json).

The key hashes everything that can change what the React side renders; the
Flutter side is not an input, so Flutter-only edits (and Flutter-only manifest
fields) never invalidate a capture:

  * raft-source commit + a digest of its uncommitted changes;
  * the case JSON minus its Flutter-only fields (id, fixture/props, viewport,
    theme, locale, capture selector + interactions, ...);
  * the fixture files the case's host reads (full bytes) and, for the other
    fixtures, their route/list structure (the generated spec registers every
    fixture's routes for every case);
  * the host .tsx file(s) that render the case (plus any other host file whose
    top-level declarations they use);
  * the capture machinery: tool/parity-ext-web.mjs, the spec/config patches
    (repr'd with this worktree's path normalised), tool/parity and the helper
    modules that patch the official spec, reference patches, cached fonts;
  * render flags (text rendering mode, Chromium args, deviceScaleFactor).

Entries are written temp + rename (png first, metadata last; an entry exists
once its metadata does), so concurrent worktrees can share the directory.
"""
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess

# Fields only the Flutter provider (or humans) read; never part of the key.
FLUTTER_ONLY_TOP = ('androidCaseHint', 'notes', 'tolerance', 'reactPathHint')
FLUTTER_ONLY_CAPTURE = ('androidKey', 'androidInteractions')
VERSION = 1


def default_cache_dir(root):
    """<main checkout>/../raft-flutter-wt/.parity-cache, the same for every worktree."""
    override = os.environ.get('PARITY_EXT_CACHE')
    if override:
        return pathlib.Path(override)
    r = subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], cwd=root,
                       capture_output=True, text=True)
    main = pathlib.Path(r.stdout.strip()).parent if r.returncode == 0 and r.stdout.strip() else pathlib.Path(root)
    return main.parent / 'raft-flutter-wt' / '.parity-cache'


def sha(data):
    if isinstance(data, str):
        data = data.encode()
    return hashlib.sha256(data).hexdigest()


def tree_digest(paths):
    """Digest of file names + bytes under the given files/directories."""
    h = hashlib.sha256()
    for p in paths:
        p = pathlib.Path(p)
        files = sorted(f for f in p.rglob('*') if f.is_file()) if p.is_dir() else [p]
        for f in files:
            if f.is_file():
                h.update(f.relative_to(p.parent).as_posix().encode() + b'\0' + f.read_bytes() + b'\0')
    return h.hexdigest()


def flutter_free_case(case):
    c = {k: v for k, v in case.items() if k not in FLUTTER_ONLY_TOP}
    if isinstance(c.get('capture'), dict):
        c['capture'] = {k: v for k, v in c['capture'].items() if k not in FLUTTER_ONLY_CAPTURE}
    return c


def _canon(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(',', ':'))


# ---------------------------------------------------------------- host / fixtures
_DECL = re.compile(r'^(?:export\s+)?(?:async\s+)?(?:function|const|let|var|class|type|interface)\s+([A-Za-z_$][\w$]*)', re.M)
_FIXTURE_IMPORT = re.compile(r'virtual:parity-ext/([\w.-]+)')


class Hosts:
    """tool/parity-ext/host/*.tsx: which file(s) render which case."""

    def __init__(self, host_dir):
        self.files = {p.name: p.read_text() for p in sorted(pathlib.Path(host_dir).glob('*.tsx'))}
        self.decls = {n: set(_DECL.findall(t)) for n, t in self.files.items()}

    def claiming(self, case):
        """Host files that mention the case's area (`components.<area>.` or the quoted
        area/extKind). No claimant -> every host file (safe)."""
        parts = case['id'].split('.')
        area = parts[1] if len(parts) > 1 else ''
        props = ((case.get('variants') or [{}])[0].get('props')) or {}
        tokens = [f'components.{area}.', f'"{area}"', f"'{area}'"]
        if props.get('extKind'):
            tokens.append(f'"{props["extKind"]}"')
        hit = [n for n, t in self.files.items() if any(tok in t for tok in tokens)]
        return hit or sorted(self.files)

    def closure(self, names):
        """Add host files whose top-level declarations the chosen files use."""
        chosen = set(names)
        grew = True
        while grew:
            grew = False
            words, own = set(), set()
            for n in chosen:
                words |= set(re.findall(r'[A-Za-z_$][\w$]*', self.files[n]))
                own |= self.decls[n]
            for n, decls in self.decls.items():
                if n not in chosen and (decls - own) & words:
                    chosen.add(n)
                    grew = True
        return sorted(chosen)

    def fixtures_used(self, names):
        return sorted({m for n in names for m in _FIXTURE_IMPORT.findall(self.files[n])})


def fixture_structure(data):
    """What other fixtures contribute to a case: their route keys / route sets / list names
    (the spec registers every fixture's routes for every case)."""
    if not isinstance(data, dict):
        return None
    return {
        'keys': sorted(data),
        'routes': sorted((data.get('routes') or {}).keys()),
        'routeSets': {k: sorted(v) if isinstance(v, dict) else None for k, v in (data.get('routeSets') or {}).items()},
        'lists': sorted((data.get('lists') or {}).keys()),
        'search': bool(data.get('search')),
    }


class KeyContext:
    """Everything that is the same for all cases of a run, computed once."""

    def __init__(self, root, ext, source, machinery):
        self.root, self.ext, self.source = pathlib.Path(root), pathlib.Path(ext), pathlib.Path(source)
        self.hosts = Hosts(self.ext / 'host')
        self.fixture_bytes = {p.stem: p.read_bytes() for p in sorted((self.ext / 'fixtures').glob('*.json'))}
        self.fixture_struct = {}
        for n, b in self.fixture_bytes.items():
            try:
                self.fixture_struct[n] = fixture_structure(json.loads(b))
            except ValueError:
                self.fixture_struct[n] = sha(b)
        tool = self.root / 'tool'
        norm = str(self.root)
        self.common = sha(_canon({
            'v': VERSION,
            'raftCommit': self._git('rev-parse', 'HEAD'),
            'raftDirty': sha(self._git('status', '--short') + self._git('diff', 'HEAD')),
            'machinery': machinery.replace(norm, '<root>'),
            'files': [sha((tool / f).read_bytes()) if (tool / f).is_file() else None for f in (
                'parity-ext-web.mjs', 'parity', 'parity-baseline-web.mjs',
                'parity_baseline_repairs.py', 'parity_reference_defects.py')],
            'trees': tree_digest([tool / 'parity-fonts', tool / 'reference-patches']),
        }))

    def _git(self, *args):
        r = subprocess.run(['git', *args], cwd=self.source, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ''

    def inputs(self, case):
        hosts = self.hosts.closure(self.hosts.claiming(case))
        used = self.hosts.fixtures_used(hosts)
        return {
            'common': self.common,
            'case': flutter_free_case(case),
            'hosts': {n: sha(self.hosts.files[n]) for n in hosts},
            'fixtures': {n: sha(self.fixture_bytes[n]) for n in used if n in self.fixture_bytes},
            'otherFixtures': {n: self.fixture_struct[n] for n in self.fixture_struct if n not in used},
        }

    def key(self, case):
        return sha(_canon(self.inputs(case)))[:40]


# ---------------------------------------------------------------- storage
class Cache:
    def __init__(self, directory):
        self.dir = pathlib.Path(directory) / 'react'

    def paths(self, key):
        return (self.dir / f'{key}.png', self.dir / f'{key}.metadata.json', self.dir / f'{key}.key.json')

    def has(self, key):
        png, meta, _ = self.paths(key)
        return png.is_file() and meta.is_file()

    def restore(self, key, case_id, react_dir):
        """Copy a hit into the results dir (atomic per file)."""
        png, meta, _ = self.paths(key)
        react_dir = pathlib.Path(react_dir)
        react_dir.mkdir(parents=True, exist_ok=True)
        _atomic_copy(png, react_dir / f'{case_id}.png')
        _atomic_copy(meta, react_dir / f'{case_id}.metadata.json')

    def store(self, key, case_id, react_dir, inputs):
        """Publish a fresh capture; the metadata file lands last and marks the entry complete."""
        react_dir = pathlib.Path(react_dir)
        src_png, src_meta = react_dir / f'{case_id}.png', react_dir / f'{case_id}.metadata.json'
        if not (src_png.is_file() and src_meta.is_file()):
            return False
        self.dir.mkdir(parents=True, exist_ok=True)
        png, meta, info = self.paths(key)
        _atomic_copy(src_png, png)
        _atomic_write(info, json.dumps({'caseId': case_id, 'inputs': inputs}, indent=1, sort_keys=True))
        _atomic_copy(src_meta, meta)
        return True


def _tmp(path):
    return path.with_name(f'.{path.name}.{os.getpid()}.tmp')


def _atomic_copy(src, dst):
    tmp = _tmp(pathlib.Path(dst))
    shutil.copyfile(src, tmp)
    os.replace(tmp, dst)


def _atomic_write(dst, text):
    dst = pathlib.Path(dst)
    tmp = _tmp(dst)
    tmp.write_text(text)
    os.replace(tmp, dst)
