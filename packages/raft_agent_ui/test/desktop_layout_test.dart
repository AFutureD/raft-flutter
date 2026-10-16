import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
Widget _app(Widget child, {HfSurface? surface}) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: Scaffold(
    body: HandsFree(surface: surface, child: child),
  ),
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
          focusId: 'room#${i + 1}',
          title: 'Aria $i',
          detail: '在做 #10$i',
        ),
      ],
    ],
  ),
);

Widget _pane({HfSurface? surface, int progress = 8}) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: Scaffold(
    body: HandsFree(
      surface: surface,
      child: Center(
        child: SizedBox(
          width: 520,
          child: SingleChildScrollView(
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

    testWidgets('a page taller than the window scrolls as a whole: one '
        'scroll, a scrollbar, and no fade that hides rows', (t) async {
      _size(t, const Size(1440, 500));
      await t.pumpWidget(_app(_frame(rows: 12)));
      await t.pumpAndSettle();
      expect(find.byType(Scrollable), findsOneWidget);
      expect(find.byType(Scrollbar), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-fade-bottom')), findsNothing);
      expect(find.byKey(const ValueKey('agent-fade-top')), findsNothing);

      final page = t.state<ScrollableState>(find.byType(Scrollable));
      expect(page.position.maxScrollExtent, greaterThan(0));
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -4000));
      await t.pumpAndSettle();
      expect(page.position.pixels, page.position.maxScrollExtent);
      // The last row is whole, above the bottom of the page.
      final last = t.getRect(find.byKey(const ValueKey('row-11')));
      expect(
        last.bottom,
        lessThanOrEqualTo(t.getRect(find.byType(Scrollable)).bottom),
      );
    });

    testWidgets('a page that fits has nothing to scroll', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_app(_frame(rows: 2)));
      await t.pumpAndSettle();
      final page = t.state<ScrollableState>(find.byType(Scrollable));
      expect(page.position.maxScrollExtent, 0);
    });

    testWidgets('a long detail is as tall as its words: no scroll, no clip, '
        'no cut line, and the actions come after the last line', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(_pane());
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final detail = find.byType(HfDetail);
      for (final kind in [
        Scrollable,
        ClipRect,
        ClipRRect,
        ClipPath,
        ShaderMask,
        AnimatedOpacity,
      ]) {
        expect(
          find.descendant(of: detail, matching: find.byType(kind)),
          findsNothing,
          reason: '$kind',
        );
      }
      // Every line of progress is there, and none was cut short.
      for (var i = 0; i < 8; i++) {
        expect(find.textContaining('第 $i 条进展'), findsOneWidget);
      }
      for (final p in t.renderObjectList<RenderParagraph>(
        find.descendant(of: detail, matching: find.byType(RichText)),
      )) {
        expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
      }
      final last = t.getRect(find.textContaining('第 7 条进展'));
      expect(t.getRect(find.text('通过')).top, greaterThan(last.bottom));
    });

    testWidgets('a TV page cannot be dragged, and moves to what the agent '
        'looks at', (t) async {
      _size(t, const Size(1920, 1080));
      final controller = HfPageController();
      addTearDown(controller.dispose);
      await t.pumpWidget(
        _app(
          HfPageControllerScope(
            controller: controller,
            child: _frame(rows: 14),
          ),
          surface: HfSurface.tv,
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(Scrollbar), findsNothing);
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
      await t.pumpAndSettle();
      expect(controller.offset, 0);
      expect(controller.nextScreen(), HfPageStep.moved);
      await t.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
    });

    testWidgets('a layer with a stage lays it out beside its list', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(
        _app(
          HfStageScope(
            id: 'room#1',
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
            id: 'room#1',
            stage: const Text('the stage', key: ValueKey('stage')),
            child: _frame(rows: 1),
          ),
        ),
      );
      expect(t.getRect(find.byKey(const ValueKey('stage'))).left, stage.left);
    });

    testWidgets('the stage stands level with the row it is about', (t) async {
      _size(t, const Size(1440, 900));
      await t.pumpWidget(
        _app(
          HfStageScope(
            id: 'room#3',
            stage: const SizedBox(
              key: ValueKey('stage'),
              height: 100,
              child: Text('the stage'),
            ),
            child: _frame(),
          ),
        ),
      );
      expect(
        t.getRect(find.byKey(const ValueKey('stage'))).top,
        closeTo(t.getRect(find.byKey(const ValueKey('row-2'))).top, 1),
      );
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

    testWidgets('a phone opens the stage under its row, in the same page', (
      t,
    ) async {
      _size(t, const Size(412, 915));
      await t.pumpWidget(
        _app(
          HfStageScope(
            id: 'room#2',
            stage: const SizedBox(
              key: ValueKey('stage'),
              height: 100,
              child: Text('the stage'),
            ),
            child: _frame(),
          ),
        ),
      );
      // (The keyed row widget holds its stage; the row itself is its text.)
      final row = t.getRect(find.text('Aria 1'));
      final stage = t.getRect(find.byKey(const ValueKey('stage')));
      final next = t.getRect(find.byKey(const ValueKey('row-2')));
      expect(stage.top, greaterThan(row.bottom));
      expect(next.top, greaterThan(stage.bottom));
      expect(find.byType(Scrollable), findsOneWidget);
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
