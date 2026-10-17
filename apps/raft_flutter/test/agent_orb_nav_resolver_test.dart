import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_fuzzy.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_resolver.dart';

const _directory = OrbDirectory(
  channels: [
    OrbChannelRef(id: 'c-rf', name: 'raft-flutter'),
    OrbChannelRef(id: 'c-design', name: 'design'),
    OrbChannelRef(id: 'c-general', name: 'general'),
    OrbChannelRef(id: 'c-release', name: 'release-notes-draft'),
    OrbChannelRef(id: 'c-old', name: 'old-ideas', archived: true),
  ],
  dms: [
    OrbDmRef(id: 'd-cody', name: 'Cody', peerId: 'u-cody', peerType: 'agent'),
    OrbDmRef(id: 'd-grok', name: 'Grok', peerId: 'u-grok', peerType: 'agent'),
    OrbDmRef(
      id: 'd-codex',
      name: 'CodexMac',
      peerId: 'u-codex',
      peerType: 'agent',
    ),
  ],
  people: [
    OrbPersonRef(id: 'u-cody', name: 'Cody', type: 'agent'),
    OrbPersonRef(id: 'u-grok', name: 'Grok', type: 'agent'),
    OrbPersonRef(id: 'u-codex', name: 'CodexMac', type: 'agent'),
    OrbPersonRef(id: 'u-alice', name: 'Alice', type: 'user'),
    OrbPersonRef(id: 'u-dana', name: 'Dana Whitfield', type: 'user'),
  ],
  threads: [
    OrbThreadRef(
      parentChannelId: 'c-rf',
      parentMessageId: 'm-launch',
      title: '发布流程需要先过一遍检查清单',
      channelName: 'raft-flutter',
      threadChannelId: 't-launch',
    ),
    OrbThreadRef(
      parentChannelId: 'c-design',
      parentMessageId: 'm-icons',
      title: 'New tab bar icons',
      channelName: 'design',
    ),
  ],
);

const _flutterTwice = OrbDirectory(
  channels: [
    OrbChannelRef(id: 'c-rf', name: 'raft-flutter'),
    OrbChannelRef(id: 'c-ui', name: 'flutter-ui'),
    OrbChannelRef(id: 'c-design', name: 'design'),
  ],
);

void main() {
  group('normalization and sound', () {
    test('case, spaces, hyphens and punctuation do not matter', () {
      expect(orbNormalize('#Raft-Flutter'), 'raftflutter');
      expect(orbNormalize('RA flutter'), 'raflutter');
      expect(orbNormalize('ＲＡＦＴ　flutter！'), 'raftflutter');
      expect(orbNormalize('设计 频道'), '设计频道');
    });

    test('sound skeleton merges common ASR confusions', () {
      expect(orbPhonetic('phone'), orbPhonetic('fone'));
      expect(orbPhonetic('cody'), orbPhonetic('kodi'));
      expect(orbPhonetic('roughslutter'), isNot(orbPhonetic('design')));
    });

    test('name scores are ordered and deterministic', () {
      expect(orbNameScore('raft-flutter', 'raftflutter'), 1);
      expect(orbNameScore('RA flutter', 'raft-flutter'), greaterThan(0.75));
      expect(orbNameScore('Roughslutter', 'raft-flutter'), greaterThan(0.72));
      expect(orbNameScore('design', 'raft-flutter'), lessThan(0.5));
      expect(
        orbNameScore('Roughslutter', 'raft-flutter'),
        orbNameScore('Roughslutter', 'raft-flutter'),
      );
    });
  });

  group('utterance table', () {
    // utterance, expected kind, expected id
    final unique = <(String, OrbKind, String)>[
      // Channels, including the ASR errors from the brief.
      ('raft-flutter', OrbKind.channel, 'c-rf'),
      ('raft-flutter 频道', OrbKind.channel, 'c-rf'),
      ('打开 raft-flutter 频道', OrbKind.channel, 'c-rf'),
      ('Roughslutter', OrbKind.channel, 'c-rf'),
      ('rough slutter channel', OrbKind.channel, 'c-rf'),
      ('RA flutter', OrbKind.channel, 'c-rf'),
      ('RA flutter 频道', OrbKind.channel, 'c-rf'),
      ('raftflutter', OrbKind.channel, 'c-rf'),
      ('raft flutter', OrbKind.channel, 'c-rf'),
      ('Raft Flutter channel', OrbKind.channel, 'c-rf'),
      ('#raft-flutter', OrbKind.channel, 'c-rf'),
      ('go to the design channel', OrbKind.channel, 'c-design'),
      ('desine', OrbKind.channel, 'c-design'),
      ('去 design 频道', OrbKind.channel, 'c-design'),
      ('general', OrbKind.channel, 'c-general'),
      ('release notes draft', OrbKind.channel, 'c-release'),
      // Private conversations and people.
      ('Cody 的私信', OrbKind.dm, 'd-cody'),
      ('Kodi 的私信', OrbKind.dm, 'd-cody'),
      ('和 Cody 聊天', OrbKind.dm, 'd-cody'),
      ('dm with Grok', OrbKind.dm, 'd-grok'),
      ('Grock', OrbKind.dm, 'd-grok'),
      ('codex mac', OrbKind.dm, 'd-codex'),
      ('Cody', OrbKind.dm, 'd-cody'),
      ('Cody 的资料', OrbKind.profile, 'u-cody'),
      ('Cody profile', OrbKind.profile, 'u-cody'),
      ('Alice', OrbKind.profile, 'u-alice'),
      ('Alice 的资料', OrbKind.profile, 'u-alice'),
      ('Dana', OrbKind.profile, 'u-dana'),
      ('Danna Whitfield 的资料', OrbKind.profile, 'u-dana'),
      // Tasks.
      ('task 136', OrbKind.task, '#136'),
      ('Task 136', OrbKind.task, '#136'),
      ('任务136', OrbKind.task, '#136'),
      ('任务 136', OrbKind.task, '#136'),
      ('#136', OrbKind.task, '#136'),
      ('打开 task #136', OrbKind.task, '#136'),
      ('第136号任务', OrbKind.task, '#136'),
      ('136号任务', OrbKind.task, '#136'),
      ('open task number 7', OrbKind.task, '#7'),
      // Pages.
      ('动态', OrbKind.page, 'activity'),
      ('打开动态', OrbKind.page, 'activity'),
      ('设置', OrbKind.page, 'settings'),
      ('任务', OrbKind.page, 'tasks'),
      ('Activity', OrbKind.page, 'activity'),
      ('Tasks', OrbKind.page, 'tasks'),
      // A discussion by the message it hangs under.
      ('发布流程 讨论', OrbKind.thread, 'm-launch'),
      ('thread tab bar icons', OrbKind.thread, 'm-icons'),
    ];
    for (final (said, kind, id) in unique) {
      test('"$said" -> ${kind.name} $id', () {
        final r = resolveOrbTarget(said, _directory);
        expect(r.error, isNull, reason: '"$said" -> ${r.error}');
        expect(
          r.match,
          isNotNull,
          reason: 'candidates: ${r.candidates.map((c) => c.title)}',
        );
        expect(r.match!.kind, kind);
        expect(r.match!.id, id);
        expect(r.match!.reason, isNotEmpty);
      });
    }

    test('a page is found by its display name only, no synonym table', () {
      // The model chooses a page by id; the fallback target matches the
      // App's own names (zh and en), nothing curated beyond them.
      for (final said in ['收件箱', '活动', '未读', 'inbox', '收藏夹']) {
        final r = resolveOrbTarget(said, _directory);
        expect(r.match?.kind == OrbKind.page, isFalse, reason: said);
      }
    });

    test('a task names its channel when the words do', () {
      final r = resolveOrbTarget('raft-flutter 的任务 136', _directory);
      expect(r.match!.kind, OrbKind.task);
      expect(r.match!.data['number'], 136);
      expect(r.match!.data['channelHint'], 'raft-flutter');
    });

    test('the kind argument decides a bare number', () {
      final task = resolveOrbTarget('136', _directory, kind: 'task');
      expect(task.match!.id, '#136');
    });

    test('"flutter" alone is ambiguous: candidates with reasons', () {
      final r = resolveOrbTarget('flutter', _flutterTwice);
      expect(r.match, isNull, reason: '${r.match?.title}');
      expect(r.candidates.map((c) => c.id), ['c-ui', 'c-rf']);
      for (final c in r.candidates) {
        expect(c.reason, contains('#'));
        expect(c.score, greaterThan(0.8));
      }
    });

    test('a channel and a person with the same name are both offered', () {
      const dir = OrbDirectory(
        channels: [OrbChannelRef(id: 'c-grace', name: 'grace')],
        people: [OrbPersonRef(id: 'u-grace', name: 'Grace', type: 'user')],
      );
      final r = resolveOrbTarget('grace', dir);
      expect(r.candidates.map((c) => c.kind).toSet(), {
        OrbKind.channel,
        OrbKind.profile,
      });
      expect(resolveOrbTarget('grace 频道', dir).match!.id, 'c-grace');
      expect(resolveOrbTarget('Grace 的资料', dir).match!.id, 'u-grace');
    });

    test('a person with no DM yet gets the profile, not a made-up DM', () {
      final profile = resolveOrbTarget('Dana', _directory);
      expect(profile.match!.kind, OrbKind.profile);
      final dm = resolveOrbTarget('Dana 的私信', _directory);
      expect(dm.match, isNull);
      expect(dm.error, contains('还没有和 Dana Whitfield 的私信'));
      expect(dm.suggestion?.id, 'u-dana');
    });

    test('nothing fits -> an error, never a guess', () {
      for (final said in ['xyzzy', 'zzzz qqqq', '火星基地', '']) {
        final r = resolveOrbTarget(said, _directory);
        expect(r.match, isNull, reason: said);
        expect(r.candidates, isEmpty, reason: said);
        expect(r.error, isNotEmpty, reason: said);
      }
    });

    test('short names must be exact', () {
      const dir = OrbDirectory(
        channels: [
          OrbChannelRef(id: 'c-ui', name: 'ui'),
          OrbChannelRef(id: 'c-qa', name: 'qa'),
        ],
      );
      expect(resolveOrbTarget('ui', dir).match!.id, 'c-ui');
      expect(resolveOrbTarget('qb', dir).match, isNull);
    });

    test('results are deterministic whatever the directory order', () {
      final reversed = OrbDirectory(
        channels: _flutterTwice.channels.reversed.toList(),
      );
      final a = resolveOrbTarget('flutter', _flutterTwice);
      final b = resolveOrbTarget('flutter', reversed);
      expect(a.candidates.map((c) => c.id), b.candidates.map((c) => c.id));
    });
  });
}
