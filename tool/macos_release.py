"""Package an ARM64 macOS app with verifiable ad-hoc signatures."""
from pathlib import Path
import plistlib
import subprocess

MACHO_MAGIC = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
               b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
               b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def run(args):
    subprocess.run([str(x) for x in args], check=True, capture_output=True)


def output(args):
    result = subprocess.run([str(x) for x in args], check=True, capture_output=True)
    return result.stdout, result.stderr


def inventory(app):
    app = Path(app).resolve()
    if (app / 'Contents/embedded.provisionprofile').exists():
        raise ValueError('Public ad-hoc builds must not include a development provisioning profile')
    binaries = []
    for path in app.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app):
                raise ValueError('macOS app contains an external symlink')
            continue
        if path.is_dir() and path.suffix in {'.app', '.xpc', '.appex'}:
            raise ValueError('Nested executable bundles require an explicit entitlement policy')
        if path.is_file():
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGIC:
                    binaries.append(path)
    if not binaries:
        raise ValueError('macOS app has no native executables')
    return sorted(binaries, key=lambda p: len(p.parts), reverse=True)


def verify(app, entitlements, version, number, arch='arm64'):
    app = Path(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier') != 'app.raft.raftFlutter'
            or info.get('CFBundleShortVersionString') != version
            or str(info.get('CFBundleVersion')) != str(number)):
        raise ValueError('macOS identity/version differs from the release plan')
    binaries = inventory(app)
    main = app / 'Contents/MacOS' / info['CFBundleExecutable']
    main_archs = output(['lipo', '-archs', main])[0].decode().split()
    if main_archs != [arch]:
        raise ValueError('macOS main executable differs from the planned architecture')
    for binary in binaries:
        if arch not in output(['lipo', '-archs', binary])[0].decode().split():
            raise ValueError(f'macOS dependency lacks {arch}: {binary.relative_to(app)}')
        run(['codesign', '--verify', '--strict', binary])
    run(['codesign', '--verify', '--deep', '--strict', app])
    signature = output(['codesign', '-d', '-vv', app])[1].decode()
    if 'Signature=adhoc' not in signature or 'Authority=' in signature:
        raise ValueError('macOS public release must have an ad-hoc signature')
    actual = plistlib.loads(output(['codesign', '-d', '--entitlements', ':-', app])[0])
    expected = plistlib.loads(Path(entitlements).read_bytes())
    if actual != expected:
        raise ValueError('macOS release entitlements differ from the reviewed configuration')
    return {'signature': 'ad-hoc', 'architecture': arch, 'nativeCodeItems': len(binaries),
            'bundleIdentifier': info['CFBundleIdentifier'], 'entitlementsVerified': True}


def package(source, stage, entitlements, version, number, arch='arm64'):
    source, stage = Path(source), Path(stage)
    stage.mkdir()
    app = stage / source.name
    run(['ditto', source, app])
    # Sign code inside out, preserving distinct root entitlements. Never use
    # --deep for signing: that applies root permissions to nested code too.
    for binary in inventory(app):
        run(['codesign', '--force', '--sign', '-', '--timestamp=none', binary])
    for framework in sorted(app.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
        if not framework.is_symlink():
            run(['codesign', '--force', '--sign', '-', '--timestamp=none', framework])
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', entitlements, app])
    checks = verify(app, entitlements, version, number, arch)
    (stage / 'READ-ME-FIRST.txt').write_text(
        'Raft for macOS 12 or newer, Apple Silicon (ARM64).\n'
        'Extract the ZIP and move Raft.app to Applications.\n'
        'This build has an ad-hoc signature and is not notarized by Apple.\n'
        'macOS may block the first launch. If you trust this download, try opening it,\n'
        'then use System Settings > Privacy & Security > Open Anyway and confirm.\n'
        'Managed Macs may not permit this exception.\n'
        'Keep existing development installations backed up: this public signing identity\n'
        'does not grant access to a development-signed installation\'s Keychain session.\n',
        encoding='utf-8')
    return checks


def verify_archive(artifact, work, app_name, entitlements, version, number, arch='arm64'):
    work = Path(work)
    work.mkdir()
    run(['ditto', '-x', '-k', artifact, work])
    apps = list(work.glob(f'*/{app_name}'))
    if len(apps) != 1:
        raise ValueError('macOS ZIP must contain exactly one packaged app')
    return verify(apps[0], entitlements, version, number, arch)
