import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
Widget _app(Widget child) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: Scaffold(body: child),
);

Widget _frame({int cards = 3}) => AgentLayerFrame(
  title: '现在所有 Agent 在做什么',
  children: [
    for (var i = 0; i < cards; i++)
      AgentPriorityCard(
        key: ValueKey('card-$i'),
        priority: AgentPriority.progress,
        title: 'Aria $i',
        weight: 2,
        detail: '在做 #10$i',
      ),
  ],
);

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('desktop window', () {
    testWidgets('a layer keeps its content to a readable column', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame()));
      final card = t.getRect(find.byKey(const ValueKey('card-0')));
      // The card is a column wide, centered, with a margin for the handle.
      expect(card.width, lessThanOrEqualTo(agentLayerContentWidth));
      expect(card.left, greaterThanOrEqualTo(agentLayerGutter));
      expect(card.center.dx, closeTo(720, 1));
    });

    testWidgets('a narrow desktop window still leaves the gutter', (t) async {
      _size(t, const Size(900, 700));
      await t.pumpWidget(_app(_frame()));
      final card = t.getRect(find.byKey(const ValueKey('card-0')));
      expect(card.left, greaterThanOrEqualTo(agentLayerGutter));
      expect(900 - card.right, greaterThanOrEqualTo(agentLayerGutter));
    });

    testWidgets('a body that is cut off says so: fade and scrollbar', (
      t,
    ) async {
      _size(t, const Size(1440, 500));
      await t.pumpWidget(_app(_frame(cards: 12)));
      await t.pumpAndSettle();
      double opacity(String key) =>
          t.widget<AnimatedOpacity>(find.byKey(ValueKey(key))).opacity;
      expect(opacity('agent-fade-bottom'), 1);
      expect(opacity('agent-fade-top'), 0);
      expect(find.byType(Scrollbar), findsOneWidget);

      // A lazy list learns its full length while it scrolls: drag to the end.
      for (var i = 0; i < 2; i++) {
        await t.drag(find.byType(ListView), const Offset(0, -4000));
        await t.pumpAndSettle();
      }
      expect(opacity('agent-fade-bottom'), 0);
      expect(opacity('agent-fade-top'), 1);
    });

    testWidgets('a body that fits has no fade', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame(cards: 2)));
      await t.pumpAndSettle();
      expect(
        t
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('agent-fade-bottom')),
            )
            .opacity,
        0,
      );
    });

    testWidgets('the dock is one bubble tall however many lines it has', (
      t,
    ) async {
      _size(t, const Size(1440, 900));
      Future<double> height(List<(AgentSpeaker, String)> lines) async {
        await t.pumpWidget(
          _app(
            Align(
              alignment: Alignment.bottomCenter,
              child: AgentVoiceDock(lines: lines, onSubmit: (_) {}),
            ),
          ),
        );
        return t.getSize(find.byType(AgentVoiceDock)).height;
      }

      final one = await height([(AgentSpeaker.agent, '现在要你验收一件事。')]);
      final two = await height([
        (AgentSpeaker.you, '现在什么情况？'),
        (AgentSpeaker.agent, '现在要你验收一件事。'),
      ]);
      expect(two, closeTo(one, 8));
      // Both lines are still there.
      expect(find.text('现在什么情况？'), findsOneWidget);
      expect(find.text('现在要你验收一件事。'), findsOneWidget);
    });
  });

  group('phone window', () {
    testWidgets('a layer is as wide as the screen, with no fade', (t) async {
      _size(t, const Size(412, 915));
      await t.pumpWidget(_app(_frame(cards: 12)));
      await t.pumpAndSettle();
      final card = t.getRect(find.byKey(const ValueKey('card-0')));
      expect(card.width, greaterThan(412 - 40));
      expect(find.byKey(const ValueKey('agent-fade-bottom')), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);
    });

    testWidgets('the dock stacks its lines', (t) async {
      _size(t, const Size(412, 915));
      await t.pumpWidget(
        _app(
          Align(
            alignment: Alignment.bottomCenter,
            child: AgentVoiceDock(
              lines: const [
                (AgentSpeaker.you, '现在什么情况？'),
                (AgentSpeaker.agent, '现在要你验收一件事。'),
              ],
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      final you = t.getRect(find.text('现在什么情况？'));
      final agent = t.getRect(find.text('现在要你验收一件事。'));
      expect(agent.top, greaterThan(you.bottom));
    });
  });
}
