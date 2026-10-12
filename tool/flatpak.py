"""Package the prepared Linux bundle and verify it in its Flatpak runtime."""
import json
from pathlib import Path
import re
import shutil
import subprocess

APP_ID = 'app.raft.raft_flutter'
RUNTIME_VERSION = '51'
FLATHUB = 'https://dl.flathub.org/repo/flathub.flatpakrepo'
BASE_LIBS = {'libc.so.6', 'libm.so.6', 'libmvec.so.1', 'libdl.so.2',
             'libpthread.so.0', 'librt.so.1', 'libresolv.so.2'}


def elf_header(path):
    with path.open('rb') as stream:
        return stream.read(4)


def manifest(source):
    return {
        'app-id': APP_ID, 'runtime': 'org.gnome.Platform',
        'runtime-version': RUNTIME_VERSION, 'sdk': 'org.gnome.Sdk',
        'command': 'raft_flutter',
        'finish-args': ['--share=network', '--share=ipc', '--socket=wayland',
                        '--socket=fallback-x11', '--socket=pulseaudio', '--device=dri',
                        '--talk-name=org.freedesktop.secrets', '--talk-name=org.freedesktop.Notifications',
                        '--env=GTK_USE_PORTAL=1'],
        'modules': [{'name': 'raft', 'buildsystem': 'simple',
                     'build-commands': ['cp -a payload/. /app/'],
                     'sources': [{'type': 'dir', 'path': str(source), 'dest': 'payload'}]}],
    }


def package(stage, artifact, root, run, capture, digest):
    # PDF helpers run in the sandbox too; host /usr/bin is not accessible there.
    notices = stage / 'data/notices/raft-media'
    provenance_path = notices / 'manifest.json'
    provenance = json.loads(provenance_path.read_text())
    helpers = stage / 'bin'
    helpers.mkdir()
    for name in ('pdfinfo', 'pdftoppm'):
        source = Path(shutil.which(name) or '')
        if not source.is_file():
            raise ValueError(f'Missing PDF helper: {name}')
        shutil.copy2(source, helpers / name)
        owner = capture(['dpkg-query', '-S', source]).splitlines()[0].split(': ')[0]
        shutil.copy2(Path('/usr/share/doc') / owner.split(':')[0] / 'copyright',
                     notices / (owner.replace(':', '_') + '.copyright'))
        provenance.setdefault('commands', []).append({
            'name': name, 'package': owner, 'version': capture(['dpkg-query', '-W', '-f=${Version}', owner]),
            'sha256': digest(helpers / name)})
        listing = capture(['ldd', source])
        if 'not found' in listing:
            raise ValueError(f'Missing host PDF dependency: {name}')
        for library, resolved in re.findall(r'^\s*(\S+) => (/\S+)', listing, re.M):
            target = stage / 'lib' / library
            if library in BASE_LIBS or target.exists():
                continue
            source_lib = Path(resolved).resolve()
            owner = capture(['dpkg-query', '-S', source_lib]).splitlines()[0].split(': ')[0]
            shutil.copy2(source_lib, target)
            shutil.copy2(Path('/usr/share/doc') / owner.split(':')[0] / 'copyright',
                         notices / (owner.replace(':', '_') + '.copyright'))
            source_package = capture(['dpkg-query', '-W', '-f=${source:Package}', owner])
            source_version = capture(['dpkg-query', '-W', '-f=${source:Version}', owner])
            provenance['libraries'].append({'library': library, 'package': owner,
                'version': capture(['dpkg-query', '-W', '-f=${Version}', owner]),
                'sourcePackage': source_package, 'sourceVersion': source_version,
                'sourceUrl': f'https://launchpad.net/ubuntu/+source/{source_package}/{source_version}',
                'sha256': digest(target)})
    for path in list(helpers.iterdir()) + list((stage / 'lib').iterdir()):
        if path.is_file() and elf_header(path) == b'\x7fELF':
            run(['patchelf', '--force-rpath', '--set-rpath',
                 '$ORIGIN/../lib' if path.parent == helpers else '$ORIGIN', path])
    for record in provenance['libraries']:
        record.setdefault('preparedSha256', record['sha256'])
        record['sha256'] = digest(stage / 'lib' / record['library'])
    for record in provenance['commands']:
        record['sha256'] = digest(helpers / record['name'])
    provenance_path.write_text(json.dumps(provenance, indent=2) + '\n')

    work = stage.parent / 'flatpak'
    payload = work / 'payload'
    payload.mkdir(parents=True)
    shutil.move(str(stage), payload / 'raft')
    stage = payload / 'raft'
    (stage / 'RUN.txt').unlink()
    (payload / 'bin').mkdir()
    launcher = payload / 'bin/raft_flutter'
    launcher.write_text('#!/bin/sh\nexport PATH="/app/raft/bin:$PATH"\nexec /app/raft/raft_flutter "$@"\n')
    launcher.chmod(0o755)
    applications = payload / 'share/applications'
    applications.mkdir(parents=True)
    desktop = (stage / 'data/applications' / f'{APP_ID}.desktop').read_text()
    desktop = re.sub(r'^Exec=.*$', 'Exec=raft_flutter %u', desktop, flags=re.M)
    desktop = re.sub(r'^Icon=.*$', f'Icon={APP_ID}', desktop, flags=re.M)
    (applications / f'{APP_ID}.desktop').write_text(desktop)
    icons = payload / 'share/icons/hicolor/256x256/apps'
    icons.mkdir(parents=True)
    shutil.copy2(root / 'apps/raft_flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png',
                 icons / f'{APP_ID}.png')
    metadata = payload / 'share/metainfo'
    metadata.mkdir(parents=True)
    shutil.copy2(root / 'packaging/flatpak' / f'{APP_ID}.metainfo.xml', metadata)
    # The GNOME runtime owns EGL/GL drivers, fontconfig and desktop base libraries.
    # Mixing Ubuntu copies with its graphics extensions can pass ldd and still
    # abort during EGL initialization. Query the real runtime before exporting.
    probe = work / 'runtime-probe'
    run(['flatpak', 'build-init', probe, APP_ID, 'org.gnome.Sdk',
         'org.gnome.Platform', RUNTIME_VERSION])
    provided = {Path(line).name for line in capture([
        'flatpak', 'build', '--runtime', probe, 'find', '/usr/lib', '-name', '*.so*']).splitlines()}
    runtime_libraries = []
    for library in (stage / 'lib').iterdir():
        if library.name in provided:
            library.unlink()
            runtime_libraries.append(library.name)
    provenance['runtimeProvidedLibraries'] = sorted(runtime_libraries)
    provenance['libraries'] = [row for row in provenance['libraries']
                               if row['library'] not in runtime_libraries]
    (stage / 'data/notices/raft-media/manifest.json').write_text(json.dumps(provenance, indent=2) + '\n')
    spec = work / f'{APP_ID}.json'
    spec.write_text(json.dumps(manifest(payload), indent=2) + '\n')
    build = work / 'build'
    repo = work / 'repo'
    run(['flatpak-builder', '--user', '--force-clean', '--disable-rofiles-fuse',
         f'--state-dir={work / "state"}', f'--repo={repo}', build, spec])
    # --runtime uses the actual runtime, not the SDK's extra development libraries.
    files = [p.relative_to(payload) for p in payload.rglob('*')
             if p.is_file() and elf_header(p) == b'\x7fELF']
    for relative in files:
        listing = capture(['flatpak', 'build', '--runtime', build, 'ldd', f'/app/{relative}'])
        if 'not found' in listing or 'version `' in listing:
            raise ValueError(f'Flatpak runtime cannot resolve {relative}: {listing}')
    run(['flatpak', 'build', '--runtime', build, '/app/raft/bin/pdfinfo', '-v'])
    run(['flatpak', 'build', '--runtime', build, '/app/raft/bin/pdftoppm', '-v'])
    run(['flatpak', 'build-bundle', f'--runtime-repo={FLATHUB}', repo, artifact, APP_ID])
    return {'appId': APP_ID, 'runtime': f'org.gnome.Platform/x86_64/{RUNTIME_VERSION}',
            'elfFilesChecked': len(files), 'runtimeProvidedLibraries': sorted(runtime_libraries), 'pdfHelpers': ['pdfinfo', 'pdftoppm'],
            'signature': 'unsigned local bundle; runtime downloaded from Flathub'}
