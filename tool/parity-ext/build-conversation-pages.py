#!/usr/bin/env python3
"""Append the conversation-page cases (inventory area 3, the rows that had no case) to the run-time
manifest ($PARITY_EXT_MANIFEST) and write tool/parity-ext/fixtures/conversation.json.

Run after build-cases.py and the other builders; idempotent: every `components.conversation.*`
case is replaced, all other cases are kept.

Derivation (raft-source 26f77ef, packages/web/src):
  components/message/ChatPanel.tsx   "Select a channel" empty main (channel=null); the footer state
                                     banners (archived + Unarchive, guest read-only, guest / member
                                     Join CTA, joint locked, joint over-limit grace), the "message not
                                     found" banner above the timeline
Not reachable in the pinned Web source, so no case (inventory 3.06): read-only quota (shared
PLAN_CONFIG maxChannels is -1 for every plan, so isReadOnlyByQuota is always false) and "Chat is
unavailable" (ChatPanel `readOnly` is passed by the visual-testing host only).
Ids: components.conversation.<scene>.<platform>.<state>.<theme>. React mounts the real ChatPanel /
ThreadPanel / MessageItem; Flutter mounts the real WorkspaceView / RaftChatView and clips the same window.
Data: tool/parity-ext/fixtures/conversation.json (`routes` + `routeSets`, answered identically by both
providers; every case pins `extFixture` so the other families' routes do not shadow them).
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
PREFIX = 'components.conversation.'
SID = 'visual-server'
CREATED = '2026-06-18T00:00:00.000Z'
OWNER = {'id': 'visual-user', 'name': 'artin', 'displayName': 'artin', 'type': 'user'}
DESIGNER = {'id': 'visual-human-designer', 'name': 'designer', 'displayName': 'Designer', 'type': 'user'}
CINDY = {'id': 'agent-cindy', 'name': 'Cindy', 'displayName': 'Cindy', 'type': 'agent'}


class Seq:
    n = 0


def msg(mid, channel, sender, content, created, **extra):
    Seq.n += 1
    m = {
        'id': mid, 'seq': Seq.n, 'serverId': SID, 'channelId': channel, 'messageType': 'chat',
        'senderType': sender['type'], 'senderId': sender['id'], 'senderName': sender['name'],
        'content': content, 'createdAt': created,
    }
    m.update(extra)
    return m


def page(messages, has_more=False, history_limited=False, summaries=None):
    return {'messages': messages, 'hasMore': has_more, 'historyLimited': history_limited,
            'threadSummariesByParentMessageId': summaries or {}}


def channel(cid, name, description='Visual testing release gates', ctype='channel', **extra):
    c = {'id': cid, 'serverId': SID, 'name': name, 'description': description, 'type': ctype,
         'createdAt': CREATED, 'joined': True}
    c.update(extra)
    return c


# ---- channels (one per footer state) --------------------------------------
GRACE_ENDS = '2026-06-21T09:00:00.000Z'
channels = [
    channel('channel-cv-open', 'design'),
    channel('channel-cv-archived', 'design-archive', archivedAt='2026-06-10T08:00:00.000Z'),
    channel('channel-cv-guest', 'guest-room'),
    channel('channel-cv-guest-join', 'guest-lobby', guestJoinable=True, joined=False),
    channel('channel-cv-join', 'product', joined=False),
    channel('channel-cv-joint-locked', 'joint-design', ctype='joint', jointBillingLocked=True),
    channel('channel-cv-joint-grace', 'joint-review', ctype='joint', jointOverLimitGraceEndsAt=GRACE_ENDS),
]
T = '2026-06-22T02:30:00.000Z'


def channel_page(cid):
    Seq.n = 0
    return page([
        msg(f'msg-{cid}-1', cid, OWNER, 'Release gates are green for the Android capture.', '2026-06-22T02:10:00.000Z'),
        msg(f'msg-{cid}-2', cid, CINDY, 'Captured the visual baselines and queued React parity.', T),
    ])


routes = {
    'GET /channels/threads/followers': {'threads': []},
    'GET /channels/threads/followed': {'threads': []},
}
for c in channels:
    routes[f'GET /messages/channel/{c["id"]}'] = channel_page(c['id'])
    routes[f'GET /tasks/channel/{c["id"]}'] = {'tasks': []}

route_sets = {
    # ?msg=<missing id>: the message context 404s -> "message not found" banner.
    'msg-missing': {'GET /messages/context/msg-missing': {'$status': 404, '$body': {'error': 'Message not found'}}},
}

fixture = {
    'name': 'raft-flutter parity extension: conversation pages',
    'scope': 'Public deterministic test data; no credentials.',
    'sourceCommit': '26f77ef97c40d3d91aa2c5e42b0fd66b8bf39fe6',
    'channels': channels,
    'dms': [],
    'thread': {'parentChannelId': 'channel-cv-open', 'parentMessageId': 'msg-thread-parent',
               'threadChannelId': 'thread-cv-1'},
    'routes': routes,
    'routeSets': {f'cv-{k}': v for k, v in route_sets.items()},
}

cases = []


def add(scene, platform, state, title, *, props=None, win=(0, 120), interactions=(), android=(), view='window',
        notes=None, route_set=None, hint=None):
    """win = (y, height) in column coordinates; y < 0 counts from the bottom."""
    viewport = DESKTOP if platform == 'desktop' else MOBILE
    for suffix, theme in THEMES.items():
        cid = f'{PREFIX}{scene}.{platform}.{state}.{suffix}'
        p = {'extCase': f'{scene}.{platform}.{state}', 'extKind': 'conversation', 'extFixture': 'conversation',
             'parityTheme': theme, 'platform': platform, 'view': view, 'winY': win[0], 'winH': win[1]}
        if route_set:
            p['routeSet'] = f'cv-{route_set}'
        p.update(props or {})
        c = {
            'id': cid,
            'title': f'{title} {platform} ({theme})',
            'captureType': 'component-fixture',
            'surface': f'conversation-{scene}',
            'category': 'extension/conversation',
            'suite': 'raft-flutter-extension',
            'viewport': viewport,
            'theme': theme,
            'locale': 'en',
            'variants': [{'id': 'default', 'name': 'Default', 'props': p}],
            'capture': {'selector': f"[data-visual-case='{cid}']", 'crop': 'element', 'contract': 'component-bounds',
                        'interactions': list(interactions), 'androidInteractions': list(android)},
            'reactPathHint': hint or 'packages/web/src/components/message/ChatPanel.tsx',
            'androidCaseHint': f"apps/raft_flutter/test/parity/cases/ext_conversation_pages.dart '{scene}.{platform}.{state}'",
            'tolerance': {'pixelRatio': 0.02, 'layoutDp': 1, 'ignoreAntialiasing': True},
        }
        if notes:
            c['notes'] = notes
        cases.append(c)


# ---- 3.03 no conversation selected (desktop main column) ---------------------
add('empty', 'desktop', 'no-channel', 'No conversation selected', props={'surface': 'chat', 'channel': ''},
    win=(0, 800), notes='ChatPanel channel=null: the centred "Select a channel" line.')

# ---- 3.06 channel state banners ----------------------------------------------
for platform in ('desktop', 'mobile'):
    footer = (-140, 140)
    chat = {'surface': 'chat'}
    add('banner', platform, 'archived', 'Archived channel footer', props={**chat, 'channel': 'channel-cv-archived'},
        win=footer)
    add('banner', platform, 'archived-header', 'Archived channel header badge',
        props={**chat, 'channel': 'channel-cv-archived'}, win=(0, 120))
    add('banner', platform, 'guest-readonly', 'Guest read-only footer',
        props={**chat, 'channel': 'channel-cv-guest', 'serverRole': 'guest'}, win=footer)
    add('banner', platform, 'guest-join', 'Guest join footer',
        props={**chat, 'channel': 'channel-cv-guest-join', 'serverRole': 'guest'}, win=footer)
    add('banner', platform, 'join', 'Join channel footer', props={**chat, 'channel': 'channel-cv-join'},
        win=footer)
    add('banner', platform, 'joint-locked', 'Joint channel locked footer',
        props={**chat, 'channel': 'channel-cv-joint-locked'}, win=footer)
    add('banner', platform, 'joint-grace', 'Joint channel over-limit grace banner above the composer',
        props={**chat, 'channel': 'channel-cv-joint-grace'}, win=(-240, 240))
    add('banner', platform, 'message-not-found', 'Message not found banner',
        props={**chat, 'channel': 'channel-cv-open', 'msg': 'msg-missing'}, win=(0, 240),
        route_set='msg-missing')

manifest_out = manifest_path()
manifest = json.loads(manifest_out.read_text())
manifest['cases'] = [c for c in manifest['cases'] if not c['id'].startswith(PREFIX)] + cases
manifest_out.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + '\n')
(here / 'fixtures/conversation.json').write_text(json.dumps(fixture, indent=1, ensure_ascii=False) + '\n')
print(f'{len(cases)} conversation page cases appended -> the run-time manifest ($PARITY_EXT_MANIFEST); '
      'fixture -> tool/parity-ext/fixtures/conversation.json')
