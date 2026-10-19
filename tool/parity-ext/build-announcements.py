#!/usr/bin/env python3
"""Append the account-level announcement modal cases to the run-time manifest ($PARITY_EXT_MANIFEST).

Run after build-cases.py (which regenerates the Computers cases); idempotent: every `components.announcements.*` case
is replaced, all other cases are kept.

Derivation (raft-source packages/web/src):
  components/AnnouncementModal.tsx   (Modal layer=1 closeOnBackdrop + Card)
  components/Modal.tsx               (backdrop, p-4 centring)
  store/announcementStore.ts         (pending[0] is presented)
Ids: components.announcements.<platform>.<kind>.<theme>. Props `ann` (a key
of fixtures/announcements.json), `next` (Next presses before capture).
"""
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from builders import manifest_path  # noqa: E402  (tool/parity-ext/builders.py)
THEMES = {'brutal': 'brutal-light', 'elegant': 'elegant-light', 'elegant-dark': 'elegant-dark'}
DESKTOP = {'width': 1280, 'height': 800, 'density': 1}
MOBILE = {'width': 390, 'height': 844, 'density': 3}
# kind: (announcement, Next presses, whole viewport?)
KINDS = {
    'single': ('single', 0, False),
    'multi-first': ('multi', 0, False),
    'multi-middle': ('multi', 1, False),
    'multi-last': ('multi', 2, False),
    'rich': ('rich', 0, False),
    'long': ('long', 0, False),
    'long-title': ('long-title', 0, False),
    'overlay': ('multi', 0, True),
}
PLATFORMS = {
    'desktop': (DESKTOP, list(KINDS)),
    'mobile': (MOBILE, ['single', 'multi-middle', 'rich', 'long', 'overlay']),
}
HINT = 'packages/web/src/components/AnnouncementModal.tsx (+ components/Modal.tsx)'

cases = []
for platform, (viewport, kinds) in PLATFORMS.items():
    for kind in kinds:
        ann, presses, whole = KINDS[kind]
        for suffix, theme in THEMES.items():
            cid = f'components.announcements.{platform}.{kind}.{suffix}'
            props = {'extCase': f'{platform}.{kind}', 'extKind': 'announcement', 'parityTheme': theme,
                     'platform': platform, 'ann': ann, 'next': str(presses)}
            capture = {
                'selector': 'body' if whole else '[data-testid="announcement-modal"]',
                'crop': 'viewport' if whole else 'element',
                'contract': 'viewport-with-portal' if whole else 'component-bounds',
                'interactions': [{'type': 'click', 'target': '[data-testid="announcement-next"]'}] * presses,
                'androidInteractions': [{'type': 'tap', 'key': 'announcement-next'}] * presses,
            }
            if not whole:
                capture['androidKey'] = 'announcement-modal'
            cases.append({
                'id': cid,
                'title': f'Announcement modal {platform} {kind} ({theme})',
                'captureType': 'component-fixture',
                'surface': 'announcements',
                'category': 'extension/announcements',
                'suite': 'raft-flutter-extension',
                'viewport': viewport,
                'theme': theme,
                'locale': 'en',
                'variants': [{'id': 'default', 'name': 'Default', 'props': props}],
                'capture': capture,
                'reactPathHint': HINT,
                'androidCaseHint': f"apps/raft_flutter/test/parity/cases/ext_announcements.dart '{platform}.{kind}'",
                'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
            })

path = manifest_path()
manifest = json.loads(path.read_text())
manifest['cases'] = [c for c in manifest['cases'] if not c['id'].startswith('components.announcements.')] + cases
path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
print(f'{len(cases)} announcement cases appended ({len(manifest["cases"])} total)')
