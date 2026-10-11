#!/usr/bin/env python3
"""Append the desktop-width dialog cases to the run-time manifest ($PARITY_EXT_MANIFEST).

Run after build-cases.py; idempotent: every `components.dialogs.*` case is
replaced, all other cases are kept.

Why: the official suite renders these dialogs at 390x844 only, so the desktop
(1280x800) Create channel and Create agent dialogs had no case (page inventory
4.01, 7.24). Each case reuses an OFFICIAL case on both providers:
  React  (host/DesktopDialogCases.tsx): the official host's seeded stores and
         prefill (primeCreateChannelStores / primeCreateAgentStores,
         CREATE_AGENT_CASES[props.official]) with the viewport widened.
  Flutter (cases/ext_dialogs.dart): the official ParityCase of props.official.
Capture: the whole viewport (modal over the page, like the announcement overlay).
Ids: components.dialogs.desktop.<key>.<theme>.
"""
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from builders import manifest_path  # noqa: E402  (tool/parity-ext/builders.py)
THEMES = {'brutal': 'brutal-light', 'elegant': 'elegant-light', 'elegant-dark': 'elegant-dark'}
DESKTOP = {'width': 1280, 'height': 800, 'density': 1}
CREATE_AGENT_PROPS = {'name': 'Product-QA-Bot',
                      'description': 'Watches release screenshots and reports visual regressions before merge.',
                      'machine': 'Jiachengs-MacBook-Pro'}
# key: (official case id, title, extra props). The first key is the surface default.
KEYS = {
    'create-channel': ('components.home.create-channel.dialog', 'Create channel dialog, prefilled members',
                       {'name': 'android-artifacts', 'description': 'Build reports, screenshots, release blockers',
                        'selected': 'human+agent'},
                       'packages/web/src/components/channel/CreateChannelDialog.tsx'),
    'create-agent': ('components.members.create-agent.dialog', 'Create agent dialog (Codex)',
                     {**CREATE_AGENT_PROPS, 'runtime': 'codex'},
                     'packages/web/src/components/agent/CreateAgentDialog.tsx'),
    'create-agent-error': ('components.members.create-agent.dialog-error', 'Create agent dialog, invalid name',
                           {**CREATE_AGENT_PROPS, 'runtime': 'codex'},
                           'packages/web/src/components/agent/CreateAgentDialog.tsx'),
    'create-agent-empty': ('components.members.create-agent.dialog-empty', 'Create agent dialog, nothing prefilled',
                           {**CREATE_AGENT_PROPS, 'runtime': 'codex'},
                           'packages/web/src/components/agent/CreateAgentDialog.tsx'),
    'create-agent-claude': ('components.members.create-agent.claude-dialog', 'Create agent dialog (Claude Code)',
                            {**CREATE_AGENT_PROPS, 'runtime': 'claude'},
                            'packages/web/src/components/agent/CreateAgentDialog.tsx'),
}

cases = []
for key, (official, title, extra, hint) in KEYS.items():
    for suffix, theme in THEMES.items():
        props = {'extCase': f'desktop.{key}', 'extKind': 'dialogs', 'parityTheme': theme, 'platform': 'desktop',
                 'official': official, **extra}
        cases.append({
            'id': f'components.dialogs.desktop.{key}.{suffix}',
            'title': f'{title} desktop ({theme})',
            'captureType': 'component-fixture',
            'surface': 'dialogs',
            'category': 'extension/dialogs',
            'suite': 'raft-flutter-extension',
            'viewport': DESKTOP,
            'theme': theme,
            'locale': 'en',
            'variants': [{'id': 'default', 'name': 'Default', 'props': props}],
            'capture': {'selector': 'body', 'crop': 'viewport', 'contract': 'viewport-with-portal',
                        'interactions': [], 'androidInteractions': []},
            'reactPathHint': hint + ' (official case ' + official + ' at 1280x800)',
            'androidCaseHint': f"apps/raft_flutter/test/parity/cases/ext_dialogs.dart 'desktop.{key}'",
            'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
        })

path = manifest_path()
manifest = json.loads(path.read_text())
manifest['cases'] = [c for c in manifest['cases'] if not c['id'].startswith('components.dialogs.')] + cases
path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
print(f'{len(cases)} desktop dialog cases appended ({len(manifest["cases"])} total)')
