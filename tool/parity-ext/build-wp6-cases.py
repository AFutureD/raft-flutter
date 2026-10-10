#!/usr/bin/env python3
"""Append the work package 6 (task and settings leftovers) cases to
tool/parity-ext/cases.json and write tool/parity-ext/fixtures/wp6.json.

Run after every other build-*.py (append-only for the other families;
idempotent: every `components.wp6.*` case is replaced).

Ids (append-only, never rename): components.wp6.<surface>.<state>.<theme>

Derivation (raft-source 26f77ef, packages/web/src/components):
  task/CreateTaskDialog.tsx            create task dialog (DialogCard)
  task/TaskFilterSegmentedControl.tsx  status filter tabs with counts
  task/TasksPanel.tsx                  TaskSectionEmpty / TaskBoardColumnEmpty
                                       (dashed "No {status} tasks.")

React (host/Wp6Cases.tsx) mounts the real Web component per surface; Flutter
(cases/ext_wp6.dart) mounts the product widget on the same fixture
(fixtures/wp6.json; every route lives in a `routeSets` entry so no other case
family sees it).
"""
import json
import pathlib

here = pathlib.Path(__file__).resolve().parent
THEMES = {'brutal': 'brutal-light', 'elegant': 'elegant-light', 'elegant-dark': 'elegant-dark'}
DESKTOP = {'width': 1280, 'height': 800, 'density': 1}
MOBILE = {'width': 390, 'height': 844, 'density': 3}
PREFIX = 'components.wp6.'
CARD_DIALOG = '.fixed.inset-0 [data-slot="card"]'
DART = 'ext_wp6.dart'

taskdetail = json.loads((here / 'fixtures/taskdetail.json').read_text())
board_all = taskdetail['board']
by_number = {t['taskNumber']: t for t in board_all}

fixture = {
    'name': 'raft-flutter parity extension: work package 6 (task and settings leftovers)',
    'scope': 'Public deterministic test data; no credentials.',
    'sourceCommit': '26f77ef97c40d3d91aa2c5e42b0fd66b8bf39fe6',
    'routes': {},
    'routeSets': {},
}
# Tasks board with empty lanes: in review / done / closed have no task.
fixture['boards'] = {
    'empty-lanes': [by_number[23], by_number[22], by_number[20]],
}
fixture['filterCounts'] = {'all': 13, 'todo': 3, 'in_progress': 3, 'in_review': 2, 'done': 3, 'closed': 0}
fixture['routeSets']['wp6-board-empty-lanes'] = {'GET /tasks/server': {'tasks': fixture['boards']['empty-lanes']}}

cases = []


def add(key, title, *, surface, platform='desktop', selector, android_key=None, state=None, route_set=None,
        interactions=(), android=(), hint, notes=None, viewport=None, crop='element', contract='component-bounds',
        props=None):
    for suffix, theme in THEMES.items():
        cid = f'{PREFIX}{key}.{suffix}'
        p = {'extCase': key, 'extKind': 'wp6', 'parityTheme': theme, 'platform': platform, 'surface': surface,
             'state': state or key.split('.')[-1], **(props or {})}
        if route_set:
            p['routeSet'] = route_set
        capture = {'selector': selector or f"[data-visual-case='{cid}']", 'crop': crop, 'contract': contract,
                   'interactions': list(interactions), 'androidInteractions': list(android)}
        if android_key:
            capture['androidKey'] = android_key
        c = {
            'id': cid,
            'title': f'WP6 {title} ({theme})',
            'captureType': 'component-fixture',
            'surface': 'wp6',
            'category': 'extension/wp6',
            'suite': 'raft-flutter-extension',
            'viewport': viewport or (DESKTOP if platform == 'desktop' else MOBILE),
            'theme': theme,
            'locale': 'en',
            'variants': [{'id': 'default', 'name': 'Default', 'props': p}],
            'capture': capture,
            'reactPathHint': hint,
            'androidCaseHint': f"apps/raft_flutter/test/parity/cases/{DART} '{key}'",
            'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
        }
        if notes:
            c['notes'] = notes
        cases.append(c)


def btn(name):
    return f'role=button[name="{name}"s]'


# ---------------------------------------------------------------- tasks
CT_HINT = 'packages/web/src/components/task/CreateTaskDialog.tsx (+ ui/DialogCard.tsx)'
for plat in ('desktop', 'mobile'):
    sfx = '' if plat == 'desktop' else '-mobile'
    ph = lambda i: f'input[placeholder="Task {i}"]'
    add(f'tasks.create-dialog{sfx}', f'Create task dialog ({plat})', surface='tasks-create', platform=plat,
        selector=CARD_DIALOG, android_key='create-task-dialog', hint=CT_HINT)
    add(f'tasks.create-dialog-filled{sfx}', f'Create task dialog, one title typed ({plat})', surface='tasks-create',
        platform=plat, selector=CARD_DIALOG, android_key='create-task-dialog', hint=CT_HINT,
        interactions=[{'type': 'fill', 'target': ph(1), 'value': 'Wire the Tasks board to the new status lanes'}],
        android=[{'type': 'enter', 'key': 'create-task-title-0', 'value': 'Wire the Tasks board to the new status lanes'}])
    add(f'tasks.create-dialog-batch{sfx}', f'Create task dialog, two rows ({plat})', surface='tasks-create',
        platform=plat, selector=CARD_DIALOG, android_key='create-task-dialog', hint=CT_HINT,
        interactions=[{'type': 'fill', 'target': ph(1), 'value': 'Wire the Tasks board'},
                      {'type': 'click', 'target': btn('Add Another')},
                      {'type': 'fill', 'target': ph(2), 'value': 'Audit elegant-dark tokens'}],
        android=[{'type': 'enter', 'key': 'create-task-title-0', 'value': 'Wire the Tasks board'},
                 {'type': 'tap', 'key': 'create-task-add-row'},
                 {'type': 'enter', 'key': 'create-task-title-1', 'value': 'Audit elegant-dark tokens'}])
    add(f'tasks.create-dialog-error{sfx}', f'Create task dialog, title required ({plat})', surface='tasks-create',
        platform=plat, selector=CARD_DIALOG, android_key='create-task-dialog', hint=CT_HINT,
        interactions=[{'type': 'click', 'target': btn('Create Task')}, {'type': 'wait', 'ms': 300}],
        android=[{'type': 'tap', 'key': 'create-task-submit'}])

FILTER_HINT = 'packages/web/src/components/task/TaskFilterSegmentedControl.tsx'
for plat in ('desktop', 'mobile'):
    sfx = '' if plat == 'desktop' else '-mobile'
    add(f'tasks.filter{sfx}', f'Task filter segmented control ({plat})', surface='tasks-filter', platform=plat,
        selector='[aria-label="Filter tasks"]', android_key='task-filter', hint=FILTER_HINT, state='default')
    add(f'tasks.filter-selected{sfx}', f'Task filter segmented control, In Progress selected ({plat})',
        surface='tasks-filter', platform=plat, selector='[aria-label="Filter tasks"]', android_key='task-filter',
        hint=FILTER_HINT, state='selected')

BOARD_HINT = 'packages/web/src/components/task/TasksPanel.tsx (TaskBoardColumnEmpty / TaskSectionEmpty)'
EXPAND = [{'type': 'click', 'target': f'[aria-label="Show {label}"]'} for label in ('Done', 'Closed')]
EXPAND_ANDROID = [{'type': 'tap', 'key': f'task-group-{s}'} for s in ('done', 'closed')]
add('tasks.empty-lanes', 'Tasks board with empty lanes (desktop board)', surface='tasks-board',
    selector='[data-testid="thread-main-column"]', state='empty-lanes', route_set='wp6-board-empty-lanes',
    hint=BOARD_HINT, notes='In review is empty; Done and Closed start collapsed.')
add('tasks.empty-lanes-expanded', 'Tasks board with empty lanes, Done and Closed expanded (desktop board)',
    surface='tasks-board', selector='[data-testid="thread-main-column"]', state='empty-lanes',
    route_set='wp6-board-empty-lanes', hint=BOARD_HINT, interactions=EXPAND, android=EXPAND_ANDROID)
add('tasks.empty-lanes-mobile', 'Tasks page with empty lanes (mobile list)', surface='tasks-board',
    platform='mobile', selector='body', crop='viewport', contract='viewport-with-portal', state='empty-lanes',
    route_set='wp6-board-empty-lanes', hint=BOARD_HINT)

# ------------------------------------------------------------- settings
SETTINGS_HINT = 'packages/web/src/components/settings/SettingsPanel.tsx'
PANEL = "[data-parity-region='settings-panel']"
WAIT = {'type': 'wait', 'ms': 800}


def settings_add(key, title, *, tab, platform='desktop', selector=None, android_key=None, flags='', role='owner',
                 route_set=None, prefs=None, interactions=(), android=(), hint=SETTINGS_HINT, notes=None,
                 viewport=None):
    mobile = platform == 'mobile'
    props = {'tab': tab, 'role': role}
    if flags:
        props['flags'] = flags
    if prefs:
        props['prefs'] = prefs
    if selector is None and not mobile:
        # Desktop crops the 976px panel column; mobile the whole 390px frame.
        selector, android_key = PANEL, 'settings-panel'
    add(key, title, surface='settings', platform=platform, selector=selector, android_key=android_key,
        route_set=route_set, interactions=[WAIT, *interactions], android=android, hint=hint, notes=notes,
        viewport=viewport, props=props, state=key.split('.')[-1])


# Language & Region (SettingsPanel.tsx LanguageRegionSection): display
# language, translation mode (+ target and default view unless Off) and the
# Date & time card.
LANG = SETTINGS_HINT + '#LanguageRegionSection'
fixture['routeSets']['wp6-translation-provider-missing'] = {
    f'GET /servers/{taskdetail["serverId"]}/translation-settings': {
        'translationEnabled': True, 'translationAvailable': False, 'canManageTranslation': True}}
fixture['routeSets']['wp6-translation-server-off'] = {
    f'GET /servers/{taskdetail["serverId"]}/translation-settings': {
        'translationEnabled': False, 'translationAvailable': True, 'canManageTranslation': True}}
for plat in ('desktop', 'mobile'):
    sfx = '' if plat == 'desktop' else '-mobile'
    settings_add(f'settings.language{sfx}', f'Language & Region ({plat})', tab='language-region', platform=plat,
                 hint=LANG)
    settings_add(f'settings.language-off{sfx}', f'Language & Region, translation off ({plat})',
                 tab='language-region', platform=plat, prefs='translation-off', hint=LANG)
settings_add('settings.language-manual', 'Language & Region, manual translation, bilingual', tab='language-region',
             prefs='translation-manual', hint=LANG)
settings_add('settings.language-provider-missing', 'Language & Region, no translation provider',
             tab='language-region', route_set='wp6-translation-provider-missing', hint=LANG)
settings_add('settings.language-server-off', 'Language & Region, translation off for the server (admin)',
             tab='language-region', route_set='wp6-translation-server-off', hint=LANG)

# Account tab cards: WorkspaceModeSettingsCard and UsageDataSettingsCard.
# The account tab's content column (`flex-1 overflow-y-auto`): the workspace
# mode card is its first child, the usage data card sits in a `mt-6` wrapper.
CONTENT = "[data-parity-region='settings-panel'] > section > div.overflow-y-auto"
WM_SEL = f'{CONTENT} > label:first-child'
UD_SEL = f'{CONTENT} > div.mt-6 > [data-slot="card"]'
for plat in ('desktop', 'mobile'):
    sfx = '' if plat == 'desktop' else '-mobile'
    settings_add(f'settings.workspace-mode{sfx}', f'Account: workspace mode card ({plat})', tab='account',
                 platform=plat, selector=WM_SEL, android_key='workspace-mode-card',
                 hint=SETTINGS_HINT + '#WorkspaceModeSettingsCard')
    settings_add(f'settings.usage-data{sfx}', f'Account: usage data card ({plat})', tab='account', platform=plat,
                 flags='analytics', selector=UD_SEL, android_key='usage-data-card',
                 android=[{'type': 'reveal', 'key': 'usage-data-card'}],
                 hint='packages/web/src/components/settings/UsageDataSettings.tsx')

manifest_path = here / 'cases.json'
manifest = json.loads(manifest_path.read_text())
manifest['cases'] = [c for c in manifest['cases'] if not c['id'].startswith(PREFIX)] + cases
manifest_path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
(here / 'fixtures/wp6.json').write_text(json.dumps(fixture, indent=1, ensure_ascii=False) + '\n')
print(f'{len(cases)} wp6 cases appended -> tool/parity-ext/cases.json; fixture -> tool/parity-ext/fixtures/wp6.json')
