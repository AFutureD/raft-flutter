#!/usr/bin/env python3
"""Append the LIST PAGES cases to the run-time manifest ($PARITY_EXT_MANIFEST).

Run after build-cases.py (idempotent: every `components.list-pages.*` case is replaced, all other
cases are kept). Also writes tool/parity-ext/fixtures/listpages.json, the data both providers read.

Page-inventory rows covered (docs/parity-page-inventory.md): 2.05 2.10 2.11 2.12 4.02 4.03 4.06 4.07
5.02 5.03 5.04 5.06 5.07 5.08 5.09 5.10 5.11 6.04 6.05 6.06 6.10 8.02 8.03 8.04 8.05.

Derivation (raft-source packages/web/src/components):
  search/MessageSearchPage.tsx      full-page search (home, searching, empty, error, load more, too broad, beyond plan history)
  thread/ThreadsInbox.tsx           Activity list (filters, context menu, empty / loading / error)
  saved/SavedPanel.tsx              Saved list (item actions, empty / loading / error)
  task/TasksPanel.tsx               Tasks (filters, view toggle, status menu, loading, load more)
Ids: components.list-pages.<panel>.<key>.<theme>. React: tool/parity-ext/host/ListPagesCases.tsx; Flutter:
apps/raft_flutter/test/parity/cases/ext_list_pages.dart (keyed by the case's `extCase`).
"""
import json
import os
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from builders import manifest_path  # noqa: E402
THEMES = {'brutal': 'brutal-light', 'elegant': 'elegant-light', 'elegant-dark': 'elegant-dark'}
DESKTOP = {'width': 1280, 'height': 800, 'density': 1}
MOBILE = {'width': 390, 'height': 844, 'density': 3}
PREFIX = 'components.list-pages.'
SRC = 'packages/web/src/components/'
RAFT_SOURCE = pathlib.Path(os.environ.get(
    'PARITY_RAFT_SOURCE', '/home/kevinzhow/.slock/agents/9a92b742-8942-488c-8635-67d224ec54ab/work/raft-source'))
SHARED = RAFT_SOURCE / 'packages/visual-testing/shared'


def shared(name):
    data = json.loads((SHARED / name).read_text())
    data.pop('comment', None)
    return data


SEARCH = shared('searchResultsFixture.json')
SAVED = shared('savedMessagesFixture.json')
ACTIVITY = shared('activityResultsFixture.json')
TASKS = shared('tasksFixture.json')
INBOX_EMPTY = {'items': [], 'hasMore': False, 'totalCount': 0, 'totalUnreadCount': 0}
SEARCH_EMPTY = {'results': [], 'hasMore': False}
SEARCH_MORE = {**SEARCH, 'hasMore': True}
# Hits older than the free plan's history window: the Web page flags them "beyond plan history".
SEARCH_OLD = {**SEARCH, 'results': [{**r, 'createdAt': r['createdAt'].replace('2026-06', '2025-06')}
                                    for r in SEARCH['results']]}
SAVED_ALL = {**SAVED, 'hasMore': False, 'total': 3}

FIXTURE = {
    'name': 'raft-flutter parity extension: list pages',
    'routes': {
        'GET /messages/search': SEARCH,
        'GET /channels/saved': SAVED,
        'GET /channels/inbox': ACTIVITY,
        'GET /tasks/server': {'tasks': TASKS['tasks']},
    },
    'routeSets': {
        'search-empty': {'GET /messages/search': SEARCH_EMPTY},
        'search-pending': {'GET /messages/search': {'$pending': True}},
        'search-error': {'GET /messages/search': {'$status': 500}},
        'search-broad': {'GET /messages/search': {'$status': 400, '$body': {'code': 'QUERY_TOO_BROAD',
                                                                            'error': 'Query too broad'}}},
        'search-more': {'GET /messages/search': SEARCH_MORE},
        'search-old': {'GET /messages/search': SEARCH_OLD},
        'activity-empty': {'GET /channels/inbox': INBOX_EMPTY},
        'activity-loading': {'GET /channels/inbox': {'$pending': True}},
        'activity-error': {'GET /channels/inbox': {'$status': 500}},
        'saved-empty': {'GET /channels/saved': {'saved': [], 'hasMore': False, 'total': 0}},
        'saved-loading': {'GET /channels/saved': {'$pending': True}},
        'saved-error': {'GET /channels/saved': {'$status': 500}},
        'saved-all': {'GET /channels/saved': SAVED_ALL},
        'tasks-loading': {'GET /tasks/server': {'$pending': True}},
        'tasks-empty': {'GET /tasks/server': {'tasks': []}},
        'tasks-more': {'GET /tasks/server': {'tasks': TASKS['tasks'], 'next_cursor': 'cursor-2'}},
    },
}

CASES = []


def tid(testid):
    return f'[data-testid="{testid}"]'


def add(key, title, kind, *, platform, hint, props=None, selector='[data-visual-case]', android_key=None,
        interactions=None, route_set=None, surface=None):
    """key = `<surface>.<name>`; one case per theme."""
    viewport = MOBILE if platform == 'mobile' else DESKTOP
    base = {'extCase': key, 'extKind': kind, 'platform': platform, 'extFixture': 'listpages'}
    base.update(props or {})
    if route_set:
        base['routeSet'] = route_set
    CASES.append({'key': key, 'title': title, 'viewport': viewport, 'selector': selector, 'android_key': android_key,
                  'hint': hint, 'props': base, 'interactions': interactions or []})


def fill(text, wait=850):
    return [{'type': 'fill', 'target': '[data-visual-case] input', 'value': text}, {'type': 'wait', 'ms': wait}]


def click(selector, wait=300):
    return [{'type': 'click', 'target': selector}, {'type': 'wait', 'ms': wait}]


# --------------------------------------------------------------------------- Search page (5.02 5.03 5.04)
SEARCH_HINT = SRC + 'search/MessageSearchPage.tsx'
HISTORY = 'android|visual parity|release notes'
for plat, box in (('phone', {'w': 390, 'h': 844}), ('desktop', {'w': 1208, 'h': 800})):
    platform = 'mobile' if plat == 'phone' else 'desktop'
    base = {'panel': 'search', 'route': '/search', **box}
    add(f'search.{plat}-home', f'Search page ({plat}): history tags and frequent', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'searchHistory': HISTORY})
    add(f'search.{plat}-searching', f'Search page ({plat}): searching skeleton', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'android'}, route_set='search-pending',
        interactions=[{'type': 'wait', 'ms': 850}])
    add(f'search.{plat}-results', f'Search page ({plat}): results', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'android'},
        interactions=[{'type': 'wait', 'ms': 850}])
    add(f'search.{plat}-no-results', f'Search page ({plat}): no results', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'zzzxq'}, route_set='search-empty',
        interactions=[{'type': 'wait', 'ms': 850}])
    add(f'search.{plat}-error', f'Search page ({plat}): search failed, retry', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'zzzxq'}, route_set='search-error',
        interactions=[{'type': 'wait', 'ms': 1500}])
    add(f'search.{plat}-too-broad', f'Search page ({plat}): query too broad', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'zzzxq'}, route_set='search-broad',
        interactions=[{'type': 'wait', 'ms': 1500}])
    add(f'search.{plat}-load-more', f'Search page ({plat}): load more', 'panel', platform=platform,
        hint=SEARCH_HINT, props={**base, 'q': 'android'}, route_set='search-more',
        interactions=[{'type': 'wait', 'ms': 850}])
    add(f'search.{plat}-beyond-history', f'Search page ({plat}): hits beyond plan history', 'panel',
        platform=platform, hint=SEARCH_HINT, props={**base, 'q': 'android'}, route_set='search-old',
        interactions=[{'type': 'wait', 'ms': 850}])
add('search.desktop-channel-filter', 'Search page (desktop): channel filter dropdown', 'panel', platform='desktop',
    hint=SEARCH_HINT, props={'panel': 'search', 'route': '/search', 'w': 1208, 'h': 800, 'q': 'android'},
    interactions=[{'type': 'wait', 'ms': 850}, *click("button[aria-label='Open channel filter']", 250)])


# --------------------------------------------------------------------------- Activity (5.06 5.07 5.08)
ACT_HINT = SRC + 'thread/ThreadsInbox.tsx'
ROW = '[data-visual-case] [data-testid="inbox-row"]'
for plat in ('phone', 'desktop'):
    platform = 'mobile' if plat == 'phone' else 'desktop'
    base = {'panel': 'activity'}
    if plat == 'phone':
        add('activity.phone-empty', 'Activity (phone): empty inbox', 'panel', platform=platform, hint=ACT_HINT,
            props={**base, 'state': 'empty'}, route_set='activity-empty')
        add('activity.phone-loading', 'Activity (phone): loading', 'panel', platform=platform, hint=ACT_HINT,
            props={**base, 'state': 'loading'}, route_set='activity-loading')
        add('activity.phone-error', 'Activity (phone): failed to load', 'panel', platform=platform, hint=ACT_HINT,
            props={**base, 'state': 'empty'}, route_set='activity-error')
    add(f'activity.{plat}-filter-unread', f'Activity ({plat}): Unread filter', 'panel', platform=platform,
        hint=ACT_HINT, props=base, interactions=[{'type': 'wait', 'ms': 850},
                                                 *click(tid('inbox-filter-unread'))])
    add(f'activity.{plat}-filter-mentions', f'Activity ({plat}): Mentions filter', 'panel', platform=platform,
        hint=ACT_HINT, props=base, interactions=[{'type': 'wait', 'ms': 850},
                                                 *click(tid('inbox-filter-mentions'))])
    add(f'activity.{plat}-context-menu', f'Activity ({plat}): row context menu', 'panel', platform=platform,
        hint=ACT_HINT, props=base, interactions=[{'type': 'wait', 'ms': 850},
                                                 {'type': 'rightclick', 'target': ROW},
                                                 {'type': 'wait', 'ms': 300}])

# --------------------------------------------------------------------------- Saved (5.09 5.10 5.11)
SAVED_HINT = SRC + 'saved/SavedPanel.tsx'
SAVED_ROW = '[data-visual-case] [role="button"]'
add('saved.desktop-list', 'Saved (desktop): saved messages list', 'panel', platform='desktop', hint=SAVED_HINT,
    props={'panel': 'saved'}, interactions=[{'type': 'wait', 'ms': 850}])
for plat in ('phone', 'desktop'):
    platform = 'mobile' if plat == 'phone' else 'desktop'
    base = {'panel': 'saved'}
    if plat == 'phone':
        add('saved.phone-empty', 'Saved (phone): empty', 'panel', platform=platform, hint=SAVED_HINT,
            props={**base, 'state': 'empty'}, route_set='saved-empty')
        add('saved.phone-loading', 'Saved (phone): loading', 'panel', platform=platform, hint=SAVED_HINT,
            props={**base, 'state': 'loading'}, route_set='saved-loading')
        add('saved.phone-error', 'Saved (phone): failed to load', 'panel', platform=platform, hint=SAVED_HINT,
            props={**base, 'state': 'empty'}, route_set='saved-error')
    add(f'saved.{plat}-actions', f'Saved ({plat}): item actions menu', 'panel', platform=platform, hint=SAVED_HINT,
        props={**base, 'state': 'results'}, route_set='saved-all',
        interactions=[{'type': 'wait', 'ms': 850}, {'type': 'rightclick', 'target': SAVED_ROW},
                      {'type': 'wait', 'ms': 300}])

# --------------------------------------------------------------------------- Tasks (6.04 6.05 6.06 6.10)
TASKS_HINT = SRC + 'task/TasksPanel.tsx'
TASK_BOX = {'desktop': {'w': 1208, 'h': 800}, 'phone': {'w': 390, 'h': 844}}
CHIP = '[data-visual-case] button:has-text("%s")'
for plat in ('desktop', 'phone'):
    platform = 'mobile' if plat == 'phone' else 'desktop'
    base = {'panel': 'tasks', 'route': '/tasks', **TASK_BOX[plat]}
    wait = {'type': 'wait', 'ms': 850}
    if plat == 'desktop':
        add('tasks.desktop-board', 'Tasks (desktop): board view (default)', 'panel', platform=platform,
            hint=TASKS_HINT, props=base, interactions=[wait])
        add('tasks.desktop-list', 'Tasks (desktop): list view', 'panel', platform=platform, hint=TASKS_HINT,
            props={**base, 'view': 'list'}, interactions=[wait])
        add('tasks.desktop-status-menu', 'Tasks (desktop): status menu', 'panel', platform=platform,
            hint=SRC + 'task/StatusBadge.tsx, TasksPanel.tsx', props={**base, 'view': 'list'},
            interactions=[wait, *click('[data-visual-case] button[data-slot="badge"]', 300)])
    for key, label in (('assignee', 'Assignee'), ('creator', 'Creator'), ('channels', 'Channel')):
        add(f'tasks.{plat}-filter-{key}', f'Tasks ({plat}): {label} filter popover', 'panel', platform=platform,
            hint=TASKS_HINT, props=base, interactions=[wait, *click(CHIP % label, 300)])
    add(f'tasks.{plat}-loading', f'Tasks ({plat}): loading skeleton', 'panel', platform=platform, hint=TASKS_HINT,
        props=base, route_set='tasks-loading', interactions=[wait])
    add(f'tasks.{plat}-load-more', f'Tasks ({plat}): Load more per lane', 'panel', platform=platform,
        hint=TASKS_HINT, props=base, route_set='tasks-more', interactions=[wait])

def build_cases():
    out = []
    for c in CASES:
        panel_surface = c['key'].split('.')[0]
        for suffix, theme in THEMES.items():
            props = dict(c['props'])
            props['parityTheme'] = theme
            out.append({
                'id': f'{PREFIX}{c["key"]}.{suffix}',
                'title': f'{c["title"]} ({theme})',
                'captureType': 'component-fixture',
                'surface': 'list-pages',
                'category': 'extension/list-pages',
                'suite': 'raft-flutter-extension',
                'viewport': c['viewport'],
                'theme': theme,
                'locale': 'en',
                'variants': [{'id': 'default', 'name': 'Default', 'props': props}],
                'capture': {'selector': c['selector'], 'crop': 'element', 'contract': 'component-bounds',
                            **({'androidKey': c['android_key']} if c['android_key'] else {}),
                            'interactions': c['interactions'], 'androidInteractions': []},
                'reactPathHint': c['hint'],
                'androidCaseHint': f"apps/raft_flutter/test/parity/cases/ext_list_pages.dart '{c['key']}'",
                'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
            })
    return out


def write_keys():
    """Case keys for ext_list_pages.dart (case_map registers one builder per key and theme)."""
    keys = ',\n'.join(f"  '{c['key']}'" for c in CASES)
    out = (here.parents[1] / 'apps/raft_flutter/test/parity/cases/ext_list_pages_keys.g.dart')
    out.write_text('// GENERATED by tool/parity-ext/build-list-pages.py; do not edit.\n'
                   '// Case key of every components.list-pages.* case.\n'
                   f'const extListPageKeys = [\n{keys},\n];\n')


def main():
    write_keys()
    (here / 'fixtures' / 'listpages.json').write_text(json.dumps(FIXTURE, indent=1, ensure_ascii=False) + '\n')
    path = manifest_path()
    manifest = json.loads(path.read_text())
    cases = build_cases()
    manifest['cases'] = [c for c in manifest['cases'] if not c['id'].startswith(PREFIX)] + cases
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
    print(f'{len(cases)} list-pages cases appended ({len(manifest["cases"])} total)')


if __name__ == '__main__':
    main()
