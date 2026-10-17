import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/mobile_tabbar_preferences.dart';
import 'package:raft_flutter/data/navigation_registry.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_resolver.dart';
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

    // The names the person says, per destination id.
    const says = <String, List<String>>{
      'activity': ['动态', '收件箱', '未读', 'activity', 'inbox', '打开动态', '去动态页面'],
      'home': ['首页', '主页', 'home', '回到首页', '聊天'],
      'tasks': ['任务', '任务板', 'tasks', 'task board', '所有任务'],
      'members': ['成员', 'Agent 列表', 'agents'],
      'saved': ['收藏', '已保存', 'saved', 'bookmarks'],
      'settings': ['设置', 'settings', '打开设置', 'open settings'],
      'search': ['搜索', 'search'],
      'computers': ['电脑', '计算机', 'computers'],
      'settings/appearance': ['外观', '深色模式', 'appearance'],
      'settings/account': ['账户', '账号', 'account'],
      'settings/notifications': ['通知设置', 'notification settings'],
      'settings/storage': ['缓存', '存储'],
      'settings/about': ['关于', 'about'],
      'release-notes': ['更新日志', 'release notes'],
      'files': ['文件', 'files'],
    };
    says.forEach((id, words) {
      for (final word in words) {
        test('"$word" is $id', () {
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
}
