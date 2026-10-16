import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
Widget _app(Widget child) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: Scaffold(body: HandsFree(child: child)),
);

Widget _frame({int rows = 3}) => HfScreenFrame(
  content: HfLayerFrame(
    title: '现在所有 Agent 在做什么',
    children: [
      for (var i = 0; i < rows; i++) ...[
        if (i > 0) const SizedBox(height: 12),
        HfRow(
          key: ValueKey('row-$i'),
          index: i + 1,
          tone: HfTone.progress,
          title: 'Aria $i',
          detail: '在做 #10$i',
        ),
      ],
    ],
  ),
);

Widget _pane({HfSurface? surface, int progress = 8, double height = 420}) =>
    MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: Scaffold(
        body: HandsFree(
          surface: surface,
          child: Center(
            child: SizedBox(
              width: 520,
              height: height,
              child: HfDetail(
                title: 'Aria 完成了一件事，等你验收',
                titleMode: HfDetailTitle.heading,
                status: '#room · 等验收',
                index: 1,
                facts: const [HfFact('要你做', '验收这件事'), HfFact('谁', 'Aria')],
                progress: [
                  for (var i = 0; i < progress; i++)
                    HfProgressLine('今天', 'Aria', '第 $i 条进展：结论都写在文档里了，请看第 3 节。'),
                ],
                actions: [HfAction('通过', kind: HfActionKind.primary)],
              ),
            ),
          ),
        ),
      ),
    );

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('desktop window', () {
    testWidgets('a layer runs margin to margin (4% each side)', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame()));
      final row = t.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.left, closeTo(1440 * .04, 1));
      // The scroll leaves room for the shadow at its right.
      expect(row.right, closeTo(1440 * .96 - 8 * 900 / 540, 2));
    });

    testWidgets('a body that is cut off says so: fade and scrollbar', (
      t,
    ) async {
      _size(t, const Size(1440, 500));
      await t.pumpWidget(_app(_frame(rows: 12)));
      await t.pumpAndSettle();
      double opacity(String key) =>
          t.widget<AnimatedOpacity>(find.byKey(ValueKey(key))).opacity;
      expect(opacity('agent-fade-bottom'), 1);
      expect(opacity('agent-fade-top'), 0);
      expect(find.byType(Scrollbar), findsOneWidget);

      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -4000));
      await t.pumpAndSettle();
      expect(opacity('agent-fade-bottom'), 0);
      expect(opacity('agent-fade-top'), 1);
    });

    testWidgets('a body that fits has no fade', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame(rows: 2)));
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

    testWidgets('a detail pane too short for its text scrolls inside its frame '
        'with a fade, and keeps its actions in view', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_pane());
      await t.pumpAndSettle();
      double opacity(String key) =>
          t.widget<AnimatedOpacity>(find.byKey(ValueKey(key))).opacity;
      expect(opacity('agent-fade-bottom'), 1);
      expect(opacity('agent-fade-top'), 0);
      expect(find.text('通过'), findsOneWidget);
      // The frame is the pane's own: the text is not drawn past it.
      final scroll = t.getRect(find.byKey(const ValueKey('hf-detail-scroll')));
      final action = t.getRect(find.text('通过'));
      expect(action.top, greaterThan(scroll.bottom));
      await t.drag(
        find.byKey(const ValueKey('hf-detail-scroll')),
        const Offset(0, -4000),
      );
      await t.pumpAndSettle();
      expect(opacity('agent-fade-bottom'), 0);
      expect(opacity('agent-fade-top'), 1);
    });

    testWidgets('a detail pane that fits has no fade', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_pane(progress: 1, height: 800));
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

    testWidgets('a TV cannot scroll a cut pane, and still fades it', (t) async {
      _size(t, const Size(1920, 1080));
      await t.pumpWidget(_pane(surface: HfSurface.tv));
      await t.pumpAndSettle();
      expect(
        t
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('agent-fade-bottom')),
            )
            .opacity,
        1,
      );
      expect(find.byType(Scrollbar), findsNothing);
      await t.drag(
        find.byKey(const ValueKey('hf-detail-scroll')),
        const Offset(0, -400),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('agent-fade-top')),
            )
            .opacity,
        0,
      );
    });

    testWidgets('a layer with a stage lays it out beside its list', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(
        _app(
          HfStageScope(
            stage: const Text('the stage', key: ValueKey('stage')),
            child: _frame(),
          ),
        ),
      );
      final row = t.getRect(find.byKey(const ValueKey('row-0')));
      final stage = t.getRect(find.byKey(const ValueKey('stage')));
      expect(stage.left, greaterThan(row.right));
      // The same place whatever the list holds.
      await t.pumpWidget(
        _app(
          HfStageScope(
            stage: const Text('the stage', key: ValueKey('stage')),
            child: _frame(rows: 1),
          ),
        ),
      );
      expect(t.getRect(find.byKey(const ValueKey('stage'))).left, stage.left);
    });

    testWidgets('a layer with no stage keeps the whole width', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame()));
      expect(
        t.getRect(find.byKey(const ValueKey('row-0'))).width,
        greaterThan(1440 * .8),
      );
    });

    testWidgets('the foot is one strip tall however many lines there are', (
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
      // The strip says the latest of them; the strip and the dock share a
      // row on a desktop.
      expect(find.text('现在什么情况？'), findsNothing);
      expect(find.text('现在要你验收一件事。'), findsOneWidget);
      expect(
        t.getRect(find.byKey(const ValueKey('agent-orb'))).left,
        greaterThan(t.getRect(find.text('现在要你验收一件事。')).right),
      );
    });
  });

  group('phone window', () {
    testWidgets('a layer is as wide as the screen, with no fade', (t) async {
      _size(t, const Size(412, 915));
      await t.pumpWidget(_app(_frame(rows: 12)));
      await t.pumpAndSettle();
      final row = t.getRect(find.byKey(const ValueKey('row-0')));
      expect(row.width, greaterThan(412 - 50));
      expect(find.byKey(const ValueKey('agent-fade-bottom')), findsNothing);
      expect(find.byType(Scrollbar), findsNothing);
    });

    testWidgets('a phone has no slot beside its list: the stage waits for '
        'the sheet', (t) async {
      _size(t, const Size(412, 915));
      await t.pumpWidget(
        _app(
          HfStageScope(
            stage: const Text('the stage', key: ValueKey('stage')),
            child: _frame(),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('stage')), findsNothing);
    });

    testWidgets('the strip sits above the dock', (t) async {
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
      final said = t.getRect(find.text('现在要你验收一件事。'));
      final mic = t.getRect(find.byKey(const ValueKey('agent-orb')));
      expect(mic.top, greaterThan(said.bottom));
    });
  });
}
