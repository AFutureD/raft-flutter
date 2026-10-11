import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/workspace_view.dart';

import 'app_global_server_selector_test.dart' show RootFixture;
import 'mobile_back_history_test.dart' show finishBackTransition;

WorkspaceController currentPage(WidgetTester tester) => tester
    .widgetList<WorkspaceView>(
      find.byWidgetPredicate((widget) => widget is WorkspaceView),
    )
    .map((widget) => widget.controller)
    .singleWhere(
      (controller) =>
          controller.presentationSource != null &&
          controller.presentationActive,
    );

void main() {
  testWidgets(
    'Live routes share accepted rows and pending sends; drafts retain their channel',
    (tester) async {
      final accepted = Completer<Map<String, dynamic>>();
      final f = RootFixture();
      f.overrides['GET /channels'] = (_) => [
        for (final id in ['ca', 'cb'])
          {
            'id': id,
            'name': id,
            'type': 'channel',
            'serverId': 'a',
            'joined': true,
          },
      ];
      f.overrides['POST /v2/messages'] = (_) => accepted.future;
      await f.mount(
        tester,
        'brutal',
        390,
        uri: Uri.parse('/s/alpha/channel/ca'),
      );
      await f.flush(tester);
      await finishBackTransition(tester);
      final source = f.workspace(tester);
      unawaited(source.selectChannel(source.channels.first, navigate: false));
      await f.flush(tester);
      final first = currentPage(tester);
      expect(identical(first.ledger, source.ledger), isTrue);
      expect(identical(first.messages.single, source.messages.single), isTrue);
      first.saveDraft('Channel A draft');
      final evaluations = f.adapter.calls
          .where((call) => call.path == '/feature-flags/evaluate')
          .length;

      unawaited(source.selectChannel(source.channels.last));
      await f.flush(tester);
      await finishBackTransition(tester);
      final second = currentPage(tester);
      expect(identical(first, second), isFalse);
      second.saveDraft('Channel B draft');
      // A covered editor can finish saving after the source selected another channel.
      first.saveDraft('Channel A final edit');
      expect(source.drafts['ca'], 'Channel A final edit');
      expect(source.drafts['cb'], 'Channel B draft');
      expect(
        f.adapter.calls
            .where((call) => call.path == '/feature-flags/evaluate')
            .length,
        evaluations,
      );

      final sending = second.send('Pending B', randomId: 'route-owner-send');
      await f.flush(tester);
      expect(source.timeline().last.content, 'Pending B');
      expect(identical(source.timeline().last, second.timeline().last), isTrue);
      final key = second.messageKey(second.timeline().last);
      accepted.complete({
        'message': {
          'id': 'accepted-b',
          'channelId': 'cb',
          'seq': '2',
          'senderId': 'alice',
          'senderName': 'Alice',
          'content': 'Pending B',
          'randomId': 'route-owner-send',
          'createdAt': '2026-10-11T00:00:00Z',
        },
      });
      await f.flush(tester);
      expect(await tester.runAsync(() => sending), isTrue);
      expect(second.timeline().last.id, 'accepted-b');
      expect(second.messageKey(second.timeline().last), key);
      expect(f.client.disposalCount, 0);
      // Even the first Back frame must paint retained A while the source is
      // still resolving its selected channel; it must never paint B in A.
      final seen = <String>[];
      f.onFrame = () {
        final page = currentPage(tester);
        if (page.location.entityId == 'ca') {
          expect(page.channel?.id, 'ca');
          seen.addAll(page.messages.map((message) => message.content));
          expect(page.messages.single.content, 'Accepted a');
        }
      };
      await tester.binding.handlePopRoute();
      await f.flush(tester);
      await finishBackTransition(tester);
      expect(seen, isNotEmpty);
      expect(source.location.entityId, 'ca');
      f.onFrame = null;
      await f.close(tester);
    },
  );
}
