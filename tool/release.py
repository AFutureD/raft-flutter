#!/usr/bin/env python3
"""Hosted CI packaging. Independent of the private native acceptance receipts."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'apps/raft_flutter'
OUT = ROOT / 'build/release'
PLATFORMS = {'windows', 'android', 'linux', 'macos'}


def run(args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def version_info(text):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+(\d+)\s*$', text, re.M)
    if not match or int(match[2]) < 1:
        raise ValueError('App pubspec must have version: X.Y.Z[-prerelease]+positive-build-number')
    return match[1], match[2]


def release_plan(config, selection, version, ref='', event=''):
    if set(config) != PLATFORMS:
        raise ValueError('Platform config must contain windows, android, linux and macos')
    selected = ([part.strip() for part in selection.split(',')] if selection.strip()
                else [name for name, row in config.items() if row['enabled']])
    if not selected or len(selected) != len(set(selected)) or any(name not in PLATFORMS for name in selected):
        raise ValueError('Select unique known platforms: windows, android, linux, macos')
    # Pull requests never receive the persistent Android signing key.
    if event == 'pull_request':
        selected = [name for name in selected if name != 'android']
        if not selected:
            raise ValueError('Pull requests require at least one unsigned desktop platform')
    if event == 'push' and ref != f'refs/tags/v{version}':
        raise ValueError('Release tag must exactly match the app pubspec version (vX.Y.Z[-prerelease])')
    return {'include': [{'platform': name, 'runner': config[name]['runner'],
                         'arch': config[name]['arch']} for name in selected]}


def emit_outputs(values):
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
            for key, value in values.items():
                stream.write(f'{key}={value}\n')
    print(json.dumps(values, indent=2))


def plan():
    version, number = version_info((APP / 'pubspec.yaml').read_text(encoding='utf-8'))
    matrix = release_plan(json.loads((ROOT / 'tool/release-platforms.json').read_text()),
                          os.environ.get('RELEASE_PLATFORMS', ''), version,
                          os.environ.get('GITHUB_REF', ''), os.environ.get('GITHUB_EVENT_NAME', ''))
    emit_outputs({'matrix': json.dumps(matrix, separators=(',', ':')), 'version': version, 'build_number': number})


def sdk():
    executable = shutil.which('flutter')
    if not executable:
        raise ValueError('Flutter action did not put Flutter on PATH')
    with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as stream:
        stream.write(f'RAFT_FLUTTER_BIN={executable}\n')


def copy_docs(destination):
    for name in ['THIRD_PARTY_NOTICES.md', 'docs/licenses', 'docs/linux-media-runtime.md']:
        source, target = ROOT / name, destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)


def windows_package(stage):
    source = APP / 'build/windows/x64/runner/Release'
    for name in ['raft_flutter.exe', 'flutter_windows.dll', 'data/icudtl.dat',
                 'data/app.so', 'data/flutter_assets', 'raft.ico', 'notification_icon.png',
                 'Microsoft.WindowsAppRuntime.Bootstrap.dll']:
        if not (source / name).exists():
            raise ValueError(f'Incomplete Windows bundle: {name}')
    shutil.copytree(source, stage)
    copy_docs(stage)
    shutil.copy2(ROOT / 'tool/windows-notification-register.ps1', stage)
    (stage / 'RUN.txt').write_text(
        'Extract the entire archive, then run raft_flutter.exe. Keep DLLs and data together.\n'
        'Requires Windows App Runtime 1.7 x64 (including singleton dependencies).\n'
        'This portable build has no Authenticode signature or installer.\n'
        'For notification click registration, use administrator PowerShell in this folder:\n'
        '$exe = (Resolve-Path ./raft_flutter.exe).Path\n'
        '$sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash\n'
        './windows-notification-register.ps1 -ExecutablePath $exe -ExpectedSha256 $sha\n'
        'Repeat registration after moving the folder. Fresh-machine and cold-click acceptance is pending.\n',
        encoding='utf-8')


def linux_package(stage):
    shutil.copytree(APP / 'build/linux/x64/release/bundle', stage, symlinks=True)
    for path in stage.rglob('*'):
        if path.is_symlink() and not path.resolve().is_relative_to(stage.resolve()):
            raise ValueError('Linux bundle contains an external symlink')
    manifest_path = stage / 'data/notices/raft-media/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    for record in manifest['libraries']:
        path = stage / 'lib' / record['library']
        notice = manifest_path.parent / (record['package'].replace(':', '_') + '.copyright')
        if not notice.is_file() or digest(path) != record['sha256']:
            raise ValueError('Linux media provenance or notice mismatch')
    elfs = []
    for path in stage.rglob('*'):
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) == b'\x7fELF':
                    elfs.append(path)
    jni = stage / 'lib/libdartjni.so'
    if any('libdartjni.so' in capture(['patchelf', '--print-needed', p]).splitlines() for p in elfs):
        raise ValueError('Unexpected Linux JNI dependency')
    if jni.exists():
        jni.unlink()
        elfs.remove(jni)
    for path in elfs:
        run(['patchelf', '--force-rpath', '--set-rpath', '$ORIGIN/lib' if path.name == 'raft_flutter' else '$ORIGIN', path])
    checks = {}
    env = {k: v for k, v in os.environ.items() if k not in {'LD_LIBRARY_PATH', 'LD_PRELOAD'}}
    for path in [stage / 'raft_flutter', stage / 'lib/libmpv.so.2', stage / 'lib/libmedia_kit_video_plugin.so']:
        listing = subprocess.check_output(['ldd', str(path)], text=True, env=env)
        if 'not found' in listing:
            raise ValueError('Incomplete relocated Linux dependency closure')
        for resolved in re.findall(r'=> (/\S+)', listing):
            target = Path(resolved).resolve()
            if target.is_relative_to(ROOT) and not target.is_relative_to(stage.resolve()):
                raise ValueError('Linux library resolves into the build tree')
        checks[str(path.relative_to(stage))] = listing
    for row in manifest['libraries']:
        row['preparedSha256'] = row['sha256']
        row['sha256'] = digest(stage / 'lib' / row['library'])
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    (stage / 'linux-dependency-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
    desktop = stage / 'data/applications/app.raft.raft_flutter.desktop'
    desktop.write_text(re.sub(r'^Exec=.*$', 'Exec=raft_flutter %u', desktop.read_text(), flags=re.M))
    copy_docs(stage)
    (stage / 'RUN.txt').write_text(
        'Run ./raft_flutter from this directory. Ubuntu 26.04 x86_64; requires compatible glibc, GTK and graphics drivers.\n'
        'PDF preview requires installed poppler-utils. Media notices/source versions are in data/notices/raft-media.\n'
        'For desktop registration put raft_flutter on PATH or adjust data/applications/app.raft.raft_flutter.desktop.\n'
        'Other distributions and full-app acceptance on this CI build have not been verified.\n')


def zip_folder(stage, destination):
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(stage.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(stage.parent))


def verify_android(apk, keystore, env, version, number):
    sdk_root = env.get('ANDROID_HOME') or env.get('ANDROID_SDK_ROOT')
    if not sdk_root:
        raise ValueError('Android SDK path is missing')
    tools = Path(sdk_root) / 'build-tools/37.0.0'
    badging = subprocess.check_output([str(tools / 'aapt'), 'dump', 'badging', str(apk)],
                                     text=True, env=env)
    identity = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    # Pinned Flutter adds 2000 to the build number for split ARM64 APKs.
    if (not identity or identity[1] != 'app.raft.raft_flutter'
            or int(identity[2]) != int(number) + 2000 or identity[3] != version):
        raise ValueError('Android APK package or compiled version differs from the release plan')
    if re.search(r'^application-debuggable(?:\s|$)', badging, re.M):
        raise ValueError('Debuggable Android APK cannot be released')
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({name.split('/')[1] for name in archive.namelist()
                       if name.startswith('lib/') and name.endswith('.so')})
    if abis != ['arm64-v8a']:
        raise ValueError('Android release must contain only ARM64 native libraries')
    cert = subprocess.check_output([
        'keytool', '-exportcert', '-keystore', str(keystore), '-alias', env['RAFT_ANDROID_KEY_ALIAS'],
        '-storepass:env', 'RAFT_ANDROID_STORE_PASSWORD',
    ], env=env, stderr=subprocess.PIPE)
    expected = hashlib.sha256(cert).hexdigest()
    signatures = subprocess.check_output([
        str(tools / 'apksigner'), 'verify', '--print-certs', str(apk),
    ], text=True, env=env)
    actual = sorted(set(value.lower() for value in re.findall(
        r'^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$', signatures, re.M)))
    if actual != [expected]:
        raise ValueError('Android APK signature differs from the configured release certificate')
    return {'package': identity[1], 'versionCode': int(identity[2]), 'versionName': identity[3],
            'abis': abis, 'certificateSHA256': expected}


def build(platform):
    version, number = version_info((APP / 'pubspec.yaml').read_text(encoding='utf-8'))
    if os.environ.get('RELEASE_VERSION', version) != version or os.environ.get('RELEASE_BUILD_NUMBER', number) != number:
        raise ValueError('Build version differs from the planned version')
    OUT.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / 'tool/release-platforms.json').read_text())[platform]
    arch = config['arch']
    name = f'raft-flutter-{version}-{platform}-{arch}'
    # No test entry points, inherited Dart defines or private local fixtures in hosted CI.
    # The only define supplied here is the public release version shown in About.
    env = dict(os.environ)
    env.pop('DART_DEFINES', None)
    android = None
    command = [sys.executable, ROOT / 'tool/flutter', 'build', 'apk' if platform == 'android' else platform,
               '--release', '--target=lib/main.dart', f'--build-name={version}', f'--build-number={number}',
               f'--dart-define=RAFT_APP_VERSION={version}']
    with tempfile.TemporaryDirectory(prefix='raft-release-') as temporary:
        work = Path(temporary)
        if platform == 'android':
            required = ['RAFT_ANDROID_KEYSTORE_BASE64', 'RAFT_ANDROID_STORE_PASSWORD',
                        'RAFT_ANDROID_KEY_PASSWORD', 'RAFT_ANDROID_KEY_ALIAS']
            if any(not env.get(key) for key in required):
                raise ValueError('Android CI requires all four RAFT_ANDROID signing secrets; debug signing is forbidden')
            keystore = work / 'release.jks'
            keystore.write_bytes(base64.b64decode(env.pop('RAFT_ANDROID_KEYSTORE_BASE64'), validate=True))
            keystore.chmod(0o600)
            env['RAFT_ANDROID_KEYSTORE_PATH'] = str(keystore)
            env['RAFT_ANDROID_SIGNING_REQUIRED'] = 'true'
            command += ['--split-per-abi', '--target-platform=android-arm64']
        run(command, cwd=APP, env=env)
        stage = work / name
        if platform == 'windows':
            windows_package(stage)
            artifact = OUT / f'{name}.zip'
            zip_folder(stage, artifact)
            signing = 'unsigned portable Windows bundle'
        elif platform == 'linux':
            linux_package(stage)
            artifact = OUT / f'{name}.tar.gz'
            with tarfile.open(artifact, 'w:gz') as archive:
                archive.add(stage, arcname=name)
            signing = 'not signed; Ubuntu 26.04 amd64 runtime'
        elif platform == 'macos':
            apps = list((APP / 'build/macos/Build/Products/Release').glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Expected one macOS app bundle')
            artifact = OUT / f'{name}.zip'
            # ditto preserves app symlinks, executable permissions and metadata.
            run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', apps[0], artifact])
            signing = 'ad-hoc; no Developer ID or notarization'
        else:
            artifact = OUT / f'{name}.apk'
            shutil.copy2(APP / 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk', artifact)
            android = verify_android(artifact, keystore, env, version, number)
            signing = 'release keystore from GitHub secrets'
    receipt = {'platform': platform, 'arch': arch, 'version': version, 'buildNumber': number,
               'commit': capture(['git', 'rev-parse', 'HEAD']),
               'flutter': json.loads((ROOT / '.fvmrc').read_text())['flutter'],
               'signing': signing, 'nativeAcceptance': 'not performed by hosted build CI',
               'artifact': artifact.name, 'sha256': digest(artifact), 'bytes': artifact.stat().st_size}
    if android is not None:
        receipt['android'] = android
    (OUT / f'{name}.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    (OUT / f'{name}.sha256').write_text(f"{receipt['sha256']}  {artifact.name}\n", encoding='utf-8')
    print(json.dumps(receipt, indent=2))


def verify_artifacts(directory, matrix, version, commit):
    expected = {row['platform'] for row in matrix['include']}
    if not expected or len(expected) != len(matrix['include']):
        raise ValueError('Invalid release platform inventory')
    receipts = [json.loads(p.read_text()) for p in directory.glob('*.json')]
    if len(receipts) != len(expected) or {r['platform'] for r in receipts} != expected:
        raise ValueError('Missing or duplicate platform receipts')
    files, checksums = [], []
    for row in receipts:
        name = row['artifact']
        if Path(name).name != name or '/' in name or '\\' in name:
            raise ValueError('Unsafe artifact filename')
        artifact = directory / name
        spec = next(r for r in matrix['include'] if r['platform'] == row['platform'])
        if (row['version'] != version or row['commit'] != commit or row['arch'] != spec['arch']
                or artifact.stat().st_size != row['bytes'] or digest(artifact) != row['sha256']):
            raise ValueError('Artifact version, source, architecture or checksum mismatch')
        files.append(artifact)
        checksums.append(f"{row['sha256']}  {name}\n")
    return receipts, files, ''.join(sorted(checksums))


def publish():
    if os.environ.get('GITHUB_EVENT_NAME') != 'push':
        raise ValueError('Publishing is permitted only for a version-tag push')
    version, _ = version_info((APP / 'pubspec.yaml').read_text(encoding='utf-8'))
    tag = f'v{version}'
    if os.environ.get('GITHUB_REF') != f'refs/tags/{tag}':
        raise ValueError('Release tag differs from pubspec')
    commit = capture(['git', 'rev-parse', 'HEAD'])
    receipts, artifacts, checksums = verify_artifacts(OUT, json.loads(os.environ['RELEASE_MATRIX']), version, commit)
    (OUT / 'CHECKSUMS.txt').write_text(checksums, encoding='utf-8')
    (OUT / 'build-manifest.json').write_text(json.dumps(receipts, indent=2) + '\n', encoding='utf-8')
    notes = OUT / 'release-notes.md'
    notes.write_text(f'Raft Flutter {tag}\n\nSource: `{commit}`. Flutter {receipts[0]["flutter"]}.\n\n'
                     + '\n'.join(f'- {r["platform"]} {r["arch"]}: {r["signing"]}.' for r in receipts)
                     + '\n\nSee `CHECKSUMS.txt` and `build-manifest.json` for source and SHA-256 provenance. '
                     'Hosted CI compiles and packages; platform functional acceptance is separate.\n'
                     '\nWindows requires Windows App Runtime 1.7 x64; extract the whole ZIP. '
                     'macOS builds are not notarized. Linux requires compatible Ubuntu 26.04 runtime dependencies.\n',
                     encoding='utf-8')
    # Never clobber published assets. Create a draft, upload everything, then publish.
    # A failed upload leaves a draft for inspection; reruns fail rather than replace bytes.
    run(['gh', 'release', 'create', tag, '--verify-tag', '--draft', '--title', f'Raft Flutter {tag}',
         '--notes-file', notes])
    run(['gh', 'release', 'upload', tag, *artifacts, OUT / 'CHECKSUMS.txt', OUT / 'build-manifest.json'])
    run(['gh', 'release', 'edit', tag, '--draft=false', f'--prerelease={str("-" in version).lower()}'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'sdk', 'build', 'publish'])
    parser.add_argument('platform', nargs='?', choices=sorted(PLATFORMS))
    args = parser.parse_args()
    if args.action == 'build':
        if not args.platform:
            parser.error('build requires a platform')
        build(args.platform)
    else:
        {'plan': plan, 'sdk': sdk, 'publish': publish}[args.action]()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f'Release stopped: {error}')
