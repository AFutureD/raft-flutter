#!/usr/bin/env python3
"""Generate the SEARCH OVERLAY part of the raft-flutter parity EXTENSION suite:
tool/parity-ext/fixtures/search-overlay.json (data both providers render) and
the `components.search-overlay.<key>.<theme>` entries of the run-time manifest ($PARITY_EXT_MANIFEST).

The manifest is append-only here: every existing entry stays byte-for-byte, only
entries whose id starts with `components.search-overlay.` are replaced.
build-cases.py keeps these entries when it regenerates the computers cases.

Component under test (raft-source packages/web/src/components/search):
  SearchOverlay.tsx (Modal + PopoverPopup + footer) wrapping
  MessageSearchPage.tsx (activateResultsInChat + overlayChrome);
  searchOverlayAnchor.ts (no desktop-shell anchor vars: position fixed,
  width min(720px, 92vw), height min(680px, 80vh), top
  max(8vh + 16px, (100vh - h) / 2)), recentConversations.ts,
  useRecentConversationEntities.ts, searchEntities.ts (ranking / exact match).

Fixture layout (every Flutter-needed datum):
  channels / dmChannels / members / agents  full entity catalog of the server
      (`official: true` = already primed by the official host's
      primeDirectVisualStores / fixtureData.json; the rest is added here)
  recentScenarios.<name>  recents seeding: `channelIds` = visit history, most
      recent first (Web: zustand recentConversationStore scope
      `<serverId>:<userId>`), `activity` = channelActivity (last message time
      per channel id; only used to pad a short visit history, Web default
      fillFromActivity=true, row limit 10, entities for computers, hidden DMs,
      archived and DMs/humans/agents without a DM channel never surface)
  search.responses[]       GET /messages/search answers keyed by trimmed
      lower-case `q` (+ optional `senderId`); `search.fallback` answers
      everything else (empty list); case prop `searchMode` = pending (never
      answered: skeleton) / error (HTTP 500: error card with Retry)
"""
import json
import pathlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
from builders import manifest_path  # noqa: E402  (tool/parity-ext/builders.py)
THEMES = {'brutal': 'brutal-light', 'elegant': 'elegant-light', 'elegant-dark': 'elegant-dark'}
SID = 'visual-server'
USER = 'visual-user'
CREATED = '2026-06-18T00:00:00.000Z'
OVERLAY = '[data-testid="desktop-search-overlay"]'
INPUT = f'{OVERLAY} input'
HINT = 'packages/web/src/components/search/SearchOverlay.tsx + MessageSearchPage.tsx (overlayChrome)'

# ---------------------------------------------------------------- fixture
channels = [
    {'id': 'channel-design', 'name': 'design', 'description': 'Product and UI decisions', 'official': True},
    {'id': 'channel-android', 'name': 'android-artifacts', 'description': 'Builds and screenshots', 'official': True},
    {'id': 'channel-release-train', 'name': 'release-train', 'description': 'Release train and store rollout'},
    {'id': 'channel-design-system', 'name': 'design-system', 'description': 'Tokens, components and review notes'},
    {'id': 'channel-design-review', 'name': 'design-review', 'description': 'Weekly visual review'},
    {'id': 'channel-product', 'name': 'product', 'description': 'Visual testing release gates'},
    {'id': 'channel-general', 'name': 'general', 'description': 'Team-wide announcements'},
]
for c in channels:
    c.update({'type': 'channel', 'createdAt': CREATED})


def dm(cid, peer_type, peer_id, name, display, description=None):
    return {'id': cid, 'name': name, 'description': None, 'type': 'dm', 'createdAt': CREATED,
            'peerType': peer_type, 'peerId': peer_id, 'peerName': name, 'peerDisplayName': display,
            'peerDescription': description}


dm_channels = [
    dm('dm-designer', 'user', 'visual-human-designer', 'designer', 'Designer', 'Product design'),
    dm('dm-jiacheng', 'user', 'visual-human-jiacheng', 'jiacheng', 'Jiacheng', 'Mobile engineer'),
    dm('dm-cindy', 'agent', 'agent-cindy', 'Cindy', 'Cindy'),
    dm('dm-product-ux', 'agent', 'agent-product-ux', 'Product-UX-Designer', 'Product UX Designer'),
    dm('dm-android-dev-4', 'agent', 'agent-android-dev-4', 'Android-Developer-4', 'Android Developer 4'),
]
members = [
    {'userId': USER, 'name': 'artin', 'displayName': 'artin', 'description': 'Owner', 'role': 'owner',
     'email': 'artin@slock.ai', 'official': True},
    {'userId': 'visual-human-designer', 'name': 'designer', 'displayName': 'Designer', 'description': 'Product design',
     'role': 'member', 'email': 'designer@slock.ai', 'official': True},
    {'userId': 'visual-human-jiacheng', 'name': 'jiacheng', 'displayName': 'Jiacheng', 'description': 'Mobile engineer',
     'role': 'member', 'email': 'jiacheng@slock.ai'},
]
agents = [
    {'id': 'agent-cindy', 'name': 'Cindy', 'displayName': 'Cindy', 'avatarUrl': 'pixel:robot',
     'description': 'Keeps visual testing release notes aligned.', 'activity': 'working',
     'activityDetail': 'Capturing visual testing baselines', 'official': True},
    {'id': 'agent-product-ux', 'name': 'Product-UX-Designer', 'displayName': 'Product UX Designer',
     'avatarUrl': 'pixel:robot',
     'description': 'Turns product feedback, screenshots, and release notes into actionable UX specs.',
     'activity': 'online', 'activityDetail': 'Reviewing screenshots', 'official': True},
    {'id': 'agent-android-dev-4', 'name': 'Android-Developer-4', 'displayName': 'Android Developer 4',
     'avatarUrl': 'pixel:robot', 'description': 'Implements shared Android/KMP UI fixes.', 'activity': 'working',
     'activityDetail': 'Running Android visual captures'},
]
# Official machines (computer entities; never listed as recents).
machines = [
    {'id': 'computer-mbp', 'name': 'Jiachengs-MacBook-Pro', 'hostname': 'Jiachengs-MacBook-Pro.local', 'official': True},
    {'id': 'computer-studio', 'name': 'Studio Test Rig', 'hostname': 'studio-test-rig.local', 'official': True},
]

# Recents: visit history (most recent first) is what the user opened; the
# activity map only pads a short history (here: one extra conversation).
recent_scenarios = {
    'default': {
        'channelIds': ['channel-design', 'dm-designer', 'channel-android', 'dm-cindy', 'channel-product',
                       'dm-jiacheng'],
        'activity': {
            'channel-design': '2026-06-19T12:20:00.000Z',
            'channel-android': '2026-06-19T11:50:00.000Z',
            'channel-release-train': '2026-06-19T10:30:00.000Z',
            'channel-product': '2026-06-18T16:00:00.000Z',
            'dm-designer': '2026-06-19T12:10:00.000Z',
            'dm-cindy': '2026-06-19T09:00:00.000Z',
        },
    },
    'empty': {'channelIds': [], 'activity': {}},
}


def hit(hid, cid, ctype, cname, sender, stype, sname, content, created, *, parent=None, thread=None):
    """One /messages/search row. `parent` = (parentChannelId, parentChannelName, parentChannelType,
    parentMessageId, parentMessageContent) for thread replies."""
    row = {
        'id': hid, 'channelId': cid, 'threadId': thread, 'parentMessageId': None, 'parentMessageContent': None,
        'parentChannelId': cid, 'parentChannelName': cname, 'parentChannelType': ctype,
        'parentChannelArchivedAt': None, 'senderId': sender, 'senderType': stype, 'senderName': sname,
        'senderAvatarUrl': None, 'channelName': cname, 'channelType': ctype, 'channelArchivedAt': None,
        'content': content, 'snippet': content, 'createdAt': created,
    }
    if parent:
        pcid, pname, ptype, pmid, pcontent = parent
        row.update({'parentChannelId': pcid, 'parentChannelName': pname, 'parentChannelType': ptype,
                    'parentMessageId': pmid, 'parentMessageContent': pcontent, 'channelType': 'thread',
                    'channelName': pname})
    return row


CINDY = ('agent-cindy', 'agent', 'Cindy')
DESIGNER = ('visual-human-designer', 'user', 'Designer')
JIACHENG = ('visual-human-jiacheng', 'user', 'Jiacheng')
ARTIN = (USER, 'user', 'artin')
ANDROID4 = ('agent-android-dev-4', 'agent', 'Android Developer 4')

android_hits = [
    hit('msg-so-a1', 'channel-android', 'channel', 'android-artifacts', *CINDY,
        'Uploaded the Android visual artifacts for the latest parity run.', '2026-06-19T12:20:00.000Z'),
    hit('msg-so-a2', 'channel-design', 'channel', 'design', *DESIGNER,
        'Can we align the Android search overlay spacing with the web palette?', '2026-06-19T11:40:00.000Z'),
    hit('msg-so-a3', 'dm-jiacheng', 'dm', 'jiacheng', *JIACHENG,
        'The Android build is green, sending screenshots in a minute.', '2026-06-19T10:05:00.000Z'),
    hit('msg-so-a4', 'channel-release-train', 'channel', 'release-train', *ANDROID4,
        'Android 0.66 release candidate is ready for store review.', '2026-06-19T08:30:00.000Z'),
    hit('msg-so-a5', 'channel-product', 'channel', 'product', *ARTIN,
        'Let us gate the release on the Android visual parity report.', '2026-06-18T17:15:00.000Z'),
    hit('msg-so-a6', 'channel-android', 'channel', 'android-artifacts', *CINDY,
        'Archived the Android screenshots from the previous run.', '2026-06-18T09:00:00.000Z'),
    hit('msg-so-a7', 'channel-design-review', 'channel', 'design-review', *DESIGNER,
        'Reviewed the Android composer crop; spacing looks right.', '2026-06-17T15:00:00.000Z'),
]
design_hits = [
    hit('msg-so-d1', 'channel-design', 'channel', 'design', *DESIGNER,
        'Design tokens are updated for the elegant dark theme.', '2026-06-19T12:15:00.000Z'),
    hit('msg-so-d2', 'dm-designer', 'dm', 'designer', *DESIGNER,
        'Sharing the latest design file with you now.', '2026-06-19T11:00:00.000Z'),
    hit('msg-so-d3', 'channel-design-system', 'channel', 'design-system', *CINDY,
        'Design system audit finished: 3 token drifts found.', '2026-06-19T09:45:00.000Z'),
    hit('msg-so-d4', 'channel-design-review', 'channel', 'design-review', *JIACHENG,
        'Design review notes for the search overlay are in the doc.', '2026-06-18T14:20:00.000Z'),
    hit('msg-so-d5', 'channel-product', 'channel', 'product', *ARTIN,
        'The design handoff is blocked on the overlay footer copy.', '2026-06-18T10:00:00.000Z'),
    hit('msg-so-d6', 'channel-design', 'channel', 'design', *CINDY,
        'Pinned the design checklist for the release.', '2026-06-17T08:30:00.000Z'),
]
PARENT = ('channel-product', 'product', 'channel', 'msg-so-parity-plan',
          'Parity plan for the extension suite: capture React first, then compare the Flutter crops one by one.')
parity_hits = [
    hit('msg-so-p1', 'thread-msg-so-parity-plan', 'thread', 'product', *CINDY,
        'Parity captures for the overlay are queued behind the computers run.', '2026-06-19T12:05:00.000Z',
        parent=PARENT, thread='thread-msg-so-parity-plan'),
    hit('msg-so-p2', 'thread-msg-so-parity-plan', 'thread', 'product', *DESIGNER,
        'Parity looks good on the home state; the loading skeleton still differs.', '2026-06-19T11:30:00.000Z',
        parent=PARENT, thread='thread-msg-so-parity-plan'),
    hit('msg-so-p3', 'channel-design', 'channel', 'design', *ARTIN,
        'Visual parity is the gate for this milestone.', '2026-06-19T09:10:00.000Z'),
    hit('msg-so-p4', 'dm-cindy', 'dm', 'Cindy', *CINDY,
        'Sending the parity summary after the next run.', '2026-06-18T18:40:00.000Z'),
    hit('msg-so-p5', 'channel-android', 'channel', 'android-artifacts', *ANDROID4,
        'Parity diff attached for the search overlay crops.', '2026-06-18T11:00:00.000Z'),
    hit('msg-so-p6', 'channel-general', 'channel', 'general', *ARTIN,
        'Reminder: parity report review on Friday.', '2026-06-17T12:00:00.000Z'),
]
sender_hits = [
    android_hits[2],
    hit('msg-so-j1', 'channel-android', 'channel', 'android-artifacts', *JIACHENG,
        'Pushed the Android signing config to the artifacts channel.', '2026-06-19T07:50:00.000Z'),
    hit('msg-so-j2', 'channel-design', 'channel', 'design', *JIACHENG,
        'Android spacing tokens match the design file now.', '2026-06-18T13:10:00.000Z'),
]
EMPTY = {'results': [], 'hasMore': False}


def response(q, rows, sender_id=None, has_more=False):
    r = {'q': q, 'body': {'results': rows, 'hasMore': has_more}}
    if sender_id:
        r['senderId'] = sender_id
    return r


search = {
    'comment': ('GET /messages/search: first rule whose `q` equals the trimmed lower-case query and whose optional '
                '`senderId` equals the request param wins; otherwise `fallback`. Case prop searchMode=pending never '
                'answers; searchMode=error answers HTTP 500. The overlay shows at most 5 message hits.'),
    'responses': [
        response('android', android_hits, has_more=True),
        response('design', design_hits, has_more=True),
        response('android', sender_hits, 'visual-human-jiacheng'),
        response('parity', parity_hits, has_more=True),
    ],
    'fallback': EMPTY,
}
fixture = {
    'name': 'raft-flutter parity extension: search overlay',
    'scope': 'Public deterministic test data; no credentials.',
    'sourceCommit': '26f77ef97c40d3d91aa2c5e42b0fd66b8bf39fe6',
    'serverId': SID, 'slug': 'visual', 'userId': USER,
    'channels': channels,
    'dmChannels': dm_channels,
    'members': members,
    'agents': agents,
    'machines': machines,
    'recentScenarios': recent_scenarios,
    'search': search,
}

# ------------------------------------------------------------------ cases
DESKTOP = {'width': 1280, 'height': 800, 'density': 1}
cases = []


def case(key, title, *, props=None, interactions=(), android=(), notes=None):
    for suffix, theme in THEMES.items():
        cid = f'components.search-overlay.{key}.{suffix}'
        p = {'extCase': key, 'extKind': 'search-overlay', 'parityTheme': theme, 'platform': 'desktop',
             **(props or {})}
        c = {
            'id': cid,
            'title': f'Search overlay {title} ({theme})',
            'captureType': 'component-fixture',
            'surface': 'search-overlay',
            'category': 'extension/search-overlay',
            'suite': 'raft-flutter-extension',
            'viewport': DESKTOP,
            'theme': theme,
            'locale': 'en',
            'variants': [{'id': 'default', 'name': 'Default', 'props': p}],
            'capture': {'selector': OVERLAY, 'crop': 'element', 'contract': 'component-bounds',
                        'androidKey': 'search-overlay-card', 'interactions': list(interactions),
                        'androidInteractions': list(android)},
            'reactPathHint': HINT,
            'androidCaseHint': f"apps/raft_flutter/test/parity/cases/ext_search_overlay.dart '{key}'",
            'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
        }
        if notes:
            c['notes'] = notes
        cases.append(c)


def typed(text):
    """Type into the overlay input; the search request is debounced 200ms, 600ms covers it."""
    return ([{'type': 'fill', 'target': INPUT, 'value': text}, {'type': 'wait', 'ms': 600}],
            [{'type': 'enterText', 'key': 'quick-switcher-input', 'text': text}, {'type': 'wait', 'ms': 600}])


NOTE_TYPED = ('Typed through the overlay input (Web: Playwright fill; Flutter: enterText on key quick-switcher-input), '
              'then wait 600ms (200ms request debounce).')

case('home', 'home: empty query, recent conversations', props={'recents': 'default'},
     notes='Empty query: "Recent conversations" rows (visit history padded from channel activity), first row selected '
           'with the return key cap. No filter row.')
case('home-empty', 'home: empty query, no recents', props={'recents': 'empty'},
     notes='No visit history and no channel activity: centered "Search everything" empty state.')

i, a = typed('android')
case('query', 'query: server entities + messages', props={'query': 'android'}, interactions=i, android=a,
     notes=NOTE_TYPED + ' "android" matches a channel and an agent (Server entities) and has 7 message hits '
     '(overlay caps at 5). Rows: Search for, Server entities, Messages.')
i, a = typed('design')
case('query-exact', 'query: exact destination row', props={'query': 'design'}, interactions=i, android=a,
     notes=NOTE_TYPED + ' "design" is exactly the channel #design: it is hoisted above the "Search for" row.')
i, a = typed('android')
case('query-selected', 'query: second row selected', props={'query': 'android'},
     interactions=i + [{'type': 'press', 'target': INPUT, 'key': 'ArrowDown'}, {'type': 'wait', 'ms': 150}],
     android=a + [{'type': 'key', 'key': 'arrowDown'}, {'type': 'wait', 'ms': 150}],
     notes=NOTE_TYPED + ' Then ArrowDown once: the first Server entities row becomes the selected row '
     '(the "Search for" row was selected by default).')
i, a = typed('xyzzy')
case('query-no-results', 'query: no results', props={'query': 'xyzzy'}, interactions=i, android=a,
     notes=NOTE_TYPED + ' Nothing matches locally and /messages/search answers an empty list: '
     '"Search for" row + no-results state.')
i, a = typed('zq roadmap')
case('query-loading', 'query: searching skeleton', props={'query': 'zq roadmap', 'searchMode': 'pending'},
     interactions=i, android=a,
     notes=NOTE_TYPED + ' No local entity matches and /messages/search never answers (searchMode=pending): '
     'Messages heading + 5 skeleton cards.')
i, a = typed('zq roadmap')
case('query-error', 'query: search failed', props={'query': 'zq roadmap', 'searchMode': 'error'},
     interactions=i, android=a,
     notes=NOTE_TYPED + ' /messages/search answers HTTP 500 (searchMode=error) and nothing matches locally: '
     'error card with Retry.')
i, a = typed('parity')
case('query-thread-group', 'query: thread reply group', props={'query': 'parity'}, interactions=i, android=a,
     notes=NOTE_TYPED + ' No local entity matches; /messages/search returns a 2-reply thread group, channel, DM '
     'and channel hits (6 total, capped at 5).')
i, a = typed('android')
case('filters-sender', 'filters: From a person', props={'query': 'android', 'senderId': 'visual-human-jiacheng'},
     interactions=i, android=a,
     notes=NOTE_TYPED + ' The From filter is pre-set through the URL (Web: ?senderId=visual-human-jiacheng, so the '
     'chip reads "From: Jiacheng" and the request carries senderId); Flutter seeds the same filter from the '
     'case prop senderId.')

# --------------------------------------------------------------- write out
(here / 'fixtures/search-overlay.json').write_text(json.dumps(fixture, indent=1, ensure_ascii=False) + '\n')
manifest_out = manifest_path()
manifest = json.loads(manifest_out.read_text())
kept = [c for c in manifest['cases'] if not c['id'].startswith('components.search-overlay.')]
manifest['cases'] = kept + cases
manifest_out.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
print(f'{len(cases)} search overlay cases (+{len(kept)} existing) -> the run-time manifest ($PARITY_EXT_MANIFEST); '
      'fixture -> tool/parity-ext/fixtures/search-overlay.json')
