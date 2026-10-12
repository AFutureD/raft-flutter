"""Build a relocatable AppImage on Ubuntu 24.04; keep graphics drivers on the host."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
APP_ID = 'app.raft.raft_flutter'


def capture(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], text=True, **kwargs).strip()


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def exclusions():
    return {line.split('#')[0].strip() for line in
            (ROOT / 'packaging/appimage/excludelist').read_text().splitlines()
            if line.split('#')[0].strip()}


def elf(path):
    with path.open('rb') as stream:
        return stream.read(4) == b'\x7fELF'


def dependencies(path, env=None):
    listing = capture(['ldd', path], env=env)
    if 'not found' in listing or 'version `' in listing:
        raise ValueError(f'Unresolved dependencies for {path}: {listing}')
    return {name: Path(target) for name, target in
            re.findall(r'^\s*(\S+) => (/\S+)', listing, re.M)}


def provenance(name, source, notices):
    source = source.resolve()
    # Handle merged-/usr packages whose recorded path differs from realpath.
    candidates = [source]
    if str(source).startswith('/usr/lib/'):
        candidates.append(Path(str(source).removeprefix('/usr')))
    owner = None
    for candidate in candidates:
        result = subprocess.run(['dpkg-query', '-S', str(candidate)], capture_output=True, text=True)
        if result.returncode == 0:
            owner = result.stdout.splitlines()[0].split(': ')[0]
            break
    if owner is None:
        raise ValueError(f'No distribution provenance for {source}')
    doc = Path('/usr/share/doc') / owner.split(':')[0] / 'copyright'
    if not doc.is_file():
        raise ValueError(f'No copyright notice for {owner}')
    shutil.copy2(doc, notices / (owner.replace(':', '_') + '.copyright'))
    version = capture(['dpkg-query', '-W', '-f=${Version}', owner])
    source_package = capture(['dpkg-query', '-W', '-f=${source:Package}', owner])
    source_version = capture(['dpkg-query', '-W', '-f=${source:Version}', owner])
    return {'library': name, 'package': owner, 'version': version,
            'sourcePackage': source_package, 'sourceVersion': source_version,
            'sourceUrl': f'https://launchpad.net/ubuntu/+source/{source_package}/{source_version}',
            'sha256': digest(source)}


def prepare_media():
    """Separate release preparation; never change the Ubuntu 26 development pins."""
    os_release = Path('/etc/os-release').read_text()
    if 'VERSION_ID="24.04"' not in os_release or capture(['dpkg', '--print-architecture']) != 'amd64':
        raise ValueError('AppImage media preparation requires Ubuntu 24.04 amd64')
    folder = ROOT / '.local/media-linux/bundle'
    if folder.exists():
        raise ValueError('Refusing to reuse media preparation from another build')
    libs, notices = folder / 'libs', folder / 'notices'
    libs.mkdir(parents=True)
    notices.mkdir()
    mpv = Path('/usr/lib/x86_64-linux-gnu/libmpv.so.2')
    sources = {'libmpv.so.2': mpv, **dependencies(mpv)}
    rows = []
    for name, path in sorted(sources.items()):
        if name in exclusions():
            continue
        rows.append(provenance(name, path, notices))
        shutil.copy2(path.resolve(), libs / name)
    (notices / 'manifest.json').write_text(json.dumps({
        'platform': 'Ubuntu 24.04 amd64 AppImage build; host glibc and device drivers',
        'libraries': rows, 'packages': [],
        'sourcePackages': 'Exact source package names, versions, SHA-256 and distribution copyright notices accompany every bundled library.'}, indent=2) + '\n')
    print(f'Prepared {len(rows)} Ubuntu 24.04 media libraries with provenance')


def download_tool(name, record, folder):
    path = folder / name
    if not path.exists():
        request = urllib.request.Request(record['url'], headers={'User-Agent': 'Raft-AppImage-CI'})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError(f'{name} download SHA-256 changed; update the reviewed tools lock')
        path.write_bytes(data)
    if digest(path) != record['sha256']:
        raise ValueError(f'{name} cached SHA-256 does not match the tools lock')
    path.chmod(0o755)
    return path


def glibc_requirement(text):
    versions = [tuple(map(int, value.split('.'))) for value in
                re.findall(r'Name: GLIBC_([0-9]+\.[0-9]+(?:\.[0-9]+)?)', text)]
    required = max(versions, default=(0, 0))
    if required > (2, 39):
        raise ValueError(f'AppImage requires GLIBC_{".".join(map(str, required))}; exceeds Ubuntu 24.04 baseline')
    return required


def package(stage, artifact, root, run, capture_output, file_digest):
    work = stage.parent / 'appimage'
    appdir = work / 'Raft.AppDir'
    appdir.mkdir(parents=True)
    shutil.move(str(stage), appdir / 'raft')
    stage = appdir / 'raft'
    (stage / 'RUN.txt').unlink()
    notices = stage / 'data/notices/raft-media'
    manifest_path = notices / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    records = {row['library']: row for row in manifest['libraries']}
    host_libraries = set()
    # Discard all device/base libraries even when a media dependency pulled them in.
    for path in (stage / 'lib').iterdir():
        if path.name in exclusions():
            path.unlink()
            records.pop(path.name, None)
            host_libraries.add(path.name)
    helpers = stage / 'bin'
    helpers.mkdir()
    commands = []
    for name in ('pdfinfo', 'pdftoppm'):
        source = Path(shutil.which(name) or '')
        if not source.is_file():
            raise ValueError(f'Missing PDF helper {name}')
        row = provenance(name, source, notices)
        row['name'] = row.pop('library')
        commands.append(row)
        shutil.copy2(source, helpers / name)
    env = {key: value for key, value in os.environ.items() if key not in {'LD_LIBRARY_PATH', 'LD_PRELOAD'}}
    files = [path for path in stage.rglob('*') if path.is_file() and elf(path)]
    # ldd resolves the recursive closure, including GTK and Secret Service plugins.
    for executable in files:
        for name, path in dependencies(executable, env=env).items():
            if name in exclusions():
                host_libraries.add(name)
                continue
            target = stage / 'lib' / name
            if not target.exists():
                records[name] = provenance(name, path, notices)
                shutil.copy2(path.resolve(), target)
    # Avoid loading host GIO modules into the bundled GLib ABI.
    (stage / 'lib/gio/modules').mkdir(parents=True)
    schemas = appdir / 'usr/share/glib-2.0/schemas'
    schemas.mkdir(parents=True)
    shutil.copy2('/usr/share/glib-2.0/schemas/gschemas.compiled', schemas)
    if Path('/usr/share/poppler').is_dir():
        shutil.copytree('/usr/share/poppler', appdir / 'usr/share/poppler', symlinks=False)
    icon = root / 'apps/raft_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png'
    shutil.copy2(icon, appdir / f'{APP_ID}.png')
    (appdir / '.DirIcon').symlink_to(f'{APP_ID}.png')
    desktop = (stage / 'data/applications' / f'{APP_ID}.desktop').read_text()
    desktop = re.sub(r'^Exec=.*$', 'Exec=raft_flutter %u', desktop, flags=re.M)
    desktop = re.sub(r'^Icon=.*$', f'Icon={APP_ID}', desktop, flags=re.M)
    (appdir / f'{APP_ID}.desktop').write_text(desktop)
    metadata = appdir / 'usr/share/metainfo'
    metadata.mkdir(parents=True)
    shutil.copy2(root / 'packaging/appimage' / f'{APP_ID}.metainfo.xml', metadata)
    launcher = appdir / 'AppRun'
    launcher.write_text('''#!/bin/sh
set -eu
app_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PATH="$app_dir/raft/bin:$PATH"
export LD_LIBRARY_PATH="$app_dir/raft/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GIO_MODULE_DIR="$app_dir/raft/lib/gio/modules"
export GSETTINGS_SCHEMA_DIR="$app_dir/usr/share/glib-2.0/schemas"
exec "$app_dir/raft/raft_flutter" "$@"
''')
    launcher.chmod(0o755)
    files = [path for path in stage.rglob('*') if path.is_file() and elf(path)]
    needed_glibc = (0, 0)
    for path in files:
        rpath = '$ORIGIN/../lib' if path.parent == helpers else '$ORIGIN/lib' if path.name == 'raft_flutter' else '$ORIGIN'
        run(['patchelf', '--force-rpath', '--set-rpath', rpath, path])
        needed_glibc = max(needed_glibc, glibc_requirement(capture_output(['readelf', '--version-info', path])))
        dependencies(path, env=env)
    for row in records.values():
        row.setdefault('preparedSha256', row['sha256'])
        row['sha256'] = file_digest(stage / 'lib' / row['library'])
    for row in commands:
        row['sha256'] = file_digest(helpers / row['name'])
    manifest.update(libraries=sorted(records.values(), key=lambda row: row['library']),
                    commands=commands, hostProvidedLibraries=sorted(host_libraries))
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    tools = json.loads((root / 'packaging/appimage/tools.json').read_text())
    tool_notices = stage / 'data/notices/appimage-runtime'
    tool_notices.mkdir()
    shutil.copy2(root / 'packaging/appimage/runtime.LICENSE', tool_notices / 'LICENSE')
    (tool_notices / 'source.json').write_text(json.dumps(tools['runtime'], indent=2) + '\n')
    cache = root / '.local/appimage-tools'
    cache.mkdir(parents=True, exist_ok=True)
    tool = download_tool('appimagetool.AppImage', tools['appimagetool'], cache)
    runtime = download_tool('runtime-x86_64', tools['runtime'], cache)
    run([tool, '--appimage-extract-and-run', '--runtime-file', runtime, appdir, artifact],
        env=dict(env, ARCH='x86_64'))
    artifact.chmod(0o755)
    return {'runtime': tools['runtime'], 'appimagetool': tools['appimagetool'],
            'buildSystem': 'Ubuntu 24.04 x86_64',
            'maximumGlibcRequired': '.'.join(map(str, needed_glibc)),
            'elfFilesChecked': len(files), 'hostProvidedLibraries': sorted(host_libraries),
            'pdfHelpers': ['pdfinfo', 'pdftoppm'],
            'launchModes': ['direct (static FUSE 3 library)', '--appimage-extract-and-run (no FUSE)']}
