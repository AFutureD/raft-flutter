import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_snapshot.dart';

import 'agent_orb_nav_tools_test.dart' show Fixture;

/// The coverage guard of the screen contract. The model acts on a page by the
/// names its controls give a screen reader; a control without a name is one it
/// cannot tell from the next. On the main pages, with fixture data, every
/// control a person can press must have a label (or a tooltip, or a hint).
///
/// When this fails, the control needs a `Semantics(label:)` or a `tooltip`
/// where it is built, not an exception here.
void main() {
  /// The pages the guard reads: `navigate` arguments, by name.
  final pages = <String, Map<String, Object?>>{
    'agent profile': {'person_id': 'a-cody'},
    'home': {'page': 'home'},
    'activity': {'page': 'activity'},
    'channel': {'channel_id': 'ca'},
    'thread': {'thread_id': 'ca-m1'},
    'dm': {'dm_id': 'dc'},
    'task detail': {'task_number': 136},
    'tasks list': {'page': 'tasks'},
    'members': {'page': 'members'},
    'settings': {'page': 'settings'},
    // Pages with text fields: the label above a field names the field.
    'account': {'page': 'settings/account'},
    'workspace settings': {'page': 'settings/server'},
    'providers': {'page': 'settings/providers'},
    'im bridges': {'page': 'settings/im-bridges'},
  };

  testWidgets('every control on the main pages has a name', (t) async {
    final fx = Fixture();
    await fx.mount(t);
    final screen = OrbScreen.of(fx.ctx.workspace);
    final nameless = <String>[];
    final seen = <String>[];

    Future<void> run(Future<Object?> Function() call) async {
      var done = false;
      unawaited(call().whenComplete(() => done = true));
      for (var i = 0; i < 40 && !done; i++) {
        await fx.f.flush(t);
      }
      expect(done, isTrue);
    }

    final navigate = orbNavigationTools().firstWhere(
      (x) => x.name == 'navigate',
    );
    for (final page in pages.entries) {
      Map<String, Object?>? moved;
      await run(() async => moved = await navigate.handler(page.value, fx.ctx));
      expect(moved!['error'], isNull, reason: '${page.key}: $moved');
      OrbScreenSnapshot? s;
      await run(() async => s = await screen.read(fx.ctx.navigatorContext));
      expect(s, isNotNull, reason: page.key);
      seen.add('${page.key}: ${s!.nodes.length} controls');
      for (final n in s!.nodes.where((n) => n.unnamed)) {
        nameless.add(
          '${page.key}: ${n.role} at ${n.at.isEmpty ? 'off-screen' : n.at} '
          'does ${n.actions.join('/')}',
        );
      }
    }
    expect(
      nameless,
      isEmpty,
      reason:
          'controls the model cannot name (give them a label or a tooltip):\n'
          '${nameless.join('\n')}\n(read: ${seen.join('; ')})',
    );
    await fx.f.close(t);
  });
}
