import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/mobile_tabbar_preferences.dart';
import 'package:raft_flutter/data/navigation_registry.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_vocabulary.dart';
import 'package:raft_ui/raft_ui.dart' show raftChinese;

void main() {
  group('App vocabulary', () {
    test('every phone tab has a vocabulary entry', () {
      for (final tab in [...MobileTabs.configurable, MobileTabs.settings]) {
        expect(
          orbVocabulary.any((d) => d.covers.contains('tab:$tab')),
          isTrue,
          reason: 'tab "$tab" has no curated vocabulary entry',
        );
      }
    });

    test('every location route is a vocabulary entry or an entity route', () {
      for (final route in RaftRoute.values) {
        if (orbEntityRoutes.contains(route)) continue;
        expect(
          orbVocabulary.any((d) => d.covers.contains('route:${route.name}')),
          isTrue,
          reason: 'route "${route.name}" has no vocabulary entry',
        );
      }
    });

    test('every workspace section and settings page has an entry', () {
      for (final s in NavigationRegistry.sections) {
        expect(
          orbVocabulary.any((d) => d.covers.contains('section:${s.id}')),
          isTrue,
          reason: 'section "${s.id}" has no vocabulary entry',
        );
      }
      for (final tab in NavigationRegistry.settingsTabs) {
        if (!tab.phone || !tab.page) {
          expect(
            orbSettingsWithoutPage.containsKey(tab.id) || !tab.phone,
            isTrue,
            reason:
                'settings page "${tab.id}" is not a phone page but is not '
                'listed in orbSettingsWithoutPage',
          );
          continue;
        }
        if (orbSettingsWithoutPage.containsKey(tab.id)) continue;
        expect(
          orbVocabulary.any((d) => d.covers.contains('settings:${tab.id}')),
          isTrue,
          reason: 'settings page "${tab.id}" has no vocabulary entry',
        );
      }
    });

    test('nothing in the code is missing from the curated vocabulary', () {
      expect(orbVocabularyGaps(), isEmpty);
    });

    test('every label is an l10n key with a Chinese name', () {
      for (final d in orbVocabulary) {
        expect(
          raftChinese.containsKey(d.label),
          isTrue,
          reason: '"${d.label}" (${d.id}) is not in the zh catalog',
        );
        expect(d.zhName, isNotEmpty);
      }
    });

    test('ids are unique and every destination can build its location', () {
      final ids = [for (final d in orbVocabulary) d.id];
      expect(ids.toSet(), hasLength(ids.length));
      for (final d in orbVocabulary) {
        if (d.channelTab != null) continue;
        expect(
          () => d.locationFor('alpha'),
          returnsNormally,
          reason: '${d.id} has no location',
        );
      }
    });

    test('every destination has a display name and a description', () {
      for (final d in orbVocabulary) {
        expect(d.zhName, isNotEmpty, reason: d.id);
        expect(d.label, isNotEmpty, reason: d.id);
        expect(
          d.about.trim(),
          isNotEmpty,
          reason: '${d.id} has no one-line description for the model',
        );
        expect(d.about.contains('\n'), isFalse, reason: '${d.id} is one line');
      }
    });

    // The display names still match the fallback `target`; nothing else does.
    const names = <String, List<String>>{
      'activity': ['动态', 'Activity', '打开动态', '去动态页面'],
      'tasks': ['任务', 'Tasks'],
      'settings': ['设置', 'settings', '打开设置', 'open settings'],
      'search': ['搜索', 'search'],
      'settings/appearance': ['外观', 'appearance'],
      'settings/about': ['关于', 'about'],
      'release-notes': ['release notes'],
      'files': ['文件', 'files'],
    };
    names.forEach((id, words) {
      for (final word in words) {
        test('the display name "$word" is $id', () {
          final r = resolveOrbTarget(word, const OrbDirectory());
          expect(r.match, isNotNull, reason: '"$word" resolved to $r');
          expect(r.match!.kind, OrbKind.page);
          expect(r.match!.id, id);
        });
      }
    });

    test('Activity is called 动态 in Chinese', () {
      final activity = orbVocabulary.firstWhere((d) => d.id == 'activity');
      expect(activity.zhName, '动态');
      expect(activity.route, RaftRoute.activity);
    });
  });

  group('the navigate declaration', () {
    final tool = orbNavigationTools().firstWhere((t) => t.name == 'navigate');
    final params = tool.declaration['parameters']! as Map;
    final props = (params['properties']! as Map).cast<String, Object?>();
    final page = (props['page']! as Map).cast<String, Object?>();

    test('page is an enum of every destination id', () {
      expect(page['type'], 'string');
      expect(page['enum'], [for (final d in orbVocabulary) d.id]);
    });

    test('every destination is in the table with its zh and en names', () {
      final description = page['description']! as String;
      final lines = description.split('\n');
      for (final d in orbVocabulary) {
        final line = lines.firstWhere(
          (l) => l.startsWith('${d.id} = '),
          orElse: () => fail('${d.id} is not in the page table'),
        );
        expect(line, contains(d.zhName), reason: d.id);
        expect(line, contains(d.label), reason: d.id);
        expect(line, contains(d.about), reason: d.id);
      }
    });

    test('"去活动看看": 动态 / Activity sits next to the activity id', () {
      // A scripted fake model cannot choose; what makes the real one choose
      // `page: activity` for 活动 is this line, so it is what is tested.
      final line = (page['description']! as String)
          .split('\n')
          .firstWhere((l) => l.startsWith('activity = '));
      expect(line, contains('动态'));
      expect(line, contains('Activity'));
      expect(line, contains('点名你的'));
    });

    test('the free-text path is only a fallback', () {
      expect(params['required'], isNull);
      for (final id in [
        'page',
        'channel_id',
        'dm_id',
        'person_id',
        'thread_id',
        'task_number',
        'target',
      ]) {
        expect(props.containsKey(id), isTrue, reason: id);
      }
      expect((props['target']! as Map)['description'], contains('最后的办法'));
      expect(tool.declaration['description'], contains('target 是最后的办法'));
    });

    test('the table stays bounded', () {
      final text = '${tool.declaration['description']}${page['description']}';
      expect(text.length, lessThan(3200), reason: '${text.length} chars');
    });
  });
}
