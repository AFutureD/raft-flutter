import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
const _phone = Size(412, 915);
const _desktop = Size(1440, 900);
const _tv = Size(1920, 1080);

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

/// A layer of [rows] numbered rows (`room#n`) whose current item, [spotlight],
/// shows [stage] in its page.
Widget _layer(
  AgentSpotlightController spotlight, {
  int rows = 14,
  HfSurface? surface,
  HfPageController? page,
}) {
  Widget stageFor(String? id) => HfDetail(
    key: const ValueKey('detail'),
    titleMode: HfDetailTitle.heading,
    title: '$id 的详情',
    status: '#room · 等验收',
    index: 1,
    facts: const [HfFact('谁', 'Aria')],
    progress: const [HfProgressLine('今天', 'Aria', '结论写在文档里。')],
    actions: [HfAction('通过', kind: HfActionKind.primary)],
  );
  return MaterialApp(
    theme: raftTheme(RaftFamily.brutal),
    home: Scaffold(
      body: HandsFree(
        surface: surface,
        child: Builder(
          builder: (context) {
            Widget screen(String? current) {
              Widget frame = HfScreenFrame(
                content: HfLayerFrame(
                  title: '房间里的事',
                  count: const HfCountLine(
                    counts: [HfCount(HfTone.decision, 2, '件')],
                  ),
                  children: [
                    for (var i = 0; i < rows; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      HfRow(
                        key: ValueKey('row-$i'),
                        index: i + 1,
                        tone: HfTone.progress,
                        focusId: 'room#${i + 1}',
                        title: 'Aria $i 做完了一件事',
                        detail: '在做 #10$i',
                      ),
                    ],
                  ],
                ),
                dock: const HfDock(),
                caption: const HfCaptionStrip(caption: '好的'),
              );
              // Always there, so the page keeps its place when a stage comes.
              frame = HfStageScope(
                id: current ?? '',
                stage: current == null ? null : stageFor(current),
                child: frame,
              );
              return frame;
            }

            return AgentSpotlight(
              controller: spotlight,
              child: ListenableBuilder(
                listenable: spotlight,
                builder: (context, _) {
                  final app = screen(spotlight.focused);
                  return page == null
                      ? app
                      : HfPageControllerScope(controller: page, child: app);
                },
              ),
            );
          },
        ),
      ),
    ),
  );
}

Rect _viewport(WidgetTester t) => t.getRect(find.byType(Scrollable));

/// The item whole inside the page's window, with its stage; when both are too
/// tall for the window, the stage is whole (a stage taller than the window
/// has its top at the top).
void _expectShown(WidgetTester t, int n, {bool stage = true}) {
  final view = _viewport(t);
  final row = t.getRect(find.text('Aria ${n - 1} 做完了一件事'));
  bool inside(Rect r) => r.top >= view.top - 1 && r.bottom <= view.bottom + 1;
  if (!stage) {
    expect(inside(row), isTrue, reason: 'row $n $row in $view');
    return;
  }
  final detail = t.getRect(find.byKey(const ValueKey('detail')));
  final together = detail.expandToInclude(row);
  if (together.height <= view.height) {
    expect(inside(row), isTrue, reason: 'row $n $row in $view');
    expect(inside(detail), isTrue, reason: 'detail $n $detail in $view');
  } else if (detail.height <= view.height) {
    expect(inside(detail), isTrue, reason: 'detail $n $detail in $view');
  } else {
    expect(detail.top, closeTo(view.top, 20), reason: 'detail $n top');
  }
}

void main() {
  for (final (name, size, surface) in [
    ('phone', _phone, null),
    ('desktop', _desktop, null),
    ('tv', _tv, HfSurface.tv),
  ]) {
    group(name, () {
      testWidgets('a layer has one scroll: the page', (t) async {
        _size(t, size);
        final spotlight = AgentSpotlightController();
        addTearDown(spotlight.dispose);
        await t.pumpWidget(_layer(spotlight, surface: surface));
        await t.pumpAndSettle();
        expect(find.byType(Scrollable), findsOneWidget);
        spotlight.focus('room#3');
        await t.pumpAndSettle();
        // With a stage open, still one.
        expect(find.byType(Scrollable), findsOneWidget);
        expect(find.byKey(const ValueKey('detail')), findsOneWidget);
      });

      testWidgets('the dock stays, and the header too except on a phone, '
          'where it is the first part of the page', (t) async {
        _size(t, size);
        final spotlight = AgentSpotlightController();
        addTearDown(spotlight.dispose);
        await t.pumpWidget(_layer(spotlight, surface: surface));
        await t.pumpAndSettle();
        final title = t.getRect(find.text('房间里的事'));
        spotlight.focus('room#14');
        await t.pumpAndSettle();
        if (size == _phone) {
          // The small bar floats; the heading scrolls up with the rows.
          expect(t.getRect(find.text('房间里的事')).top, lessThan(title.top));
        } else {
          expect(t.getRect(find.text('房间里的事')), title);
        }
        expect(
          t.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
          greaterThan(0),
        );
        if (surface == null) {
          expect(find.byKey(const ValueKey('agent-orb')), findsOneWidget);
        }
      });

      testWidgets('focusing an item scrolls it, and its stage, into view', (
        t,
      ) async {
        _size(t, size);
        final spotlight = AgentSpotlightController();
        addTearDown(spotlight.dispose);
        await t.pumpWidget(_layer(spotlight, surface: surface));
        await t.pumpAndSettle();
        for (final n in [10, 14, 6, 1, 12]) {
          spotlight.focus('room#$n');
          await t.pumpAndSettle();
          _expectShown(t, n);
        }
      });
    });
  }

  testWidgets('the scroll is animated, not a jump', (t) async {
    _size(t, _phone);
    final spotlight = AgentSpotlightController();
    addTearDown(spotlight.dispose);
    await t.pumpWidget(_layer(spotlight));
    await t.pumpAndSettle();
    final page = t.state<ScrollableState>(find.byType(Scrollable));
    spotlight.focus('room#12');
    await t.pump();
    await t.pump(const Duration(milliseconds: 20));
    await t.pump(const Duration(milliseconds: 100));
    final mid = page.position.pixels;
    await t.pumpAndSettle();
    expect(mid, greaterThan(0));
    expect(mid, lessThan(page.position.pixels));
  });

  testWidgets('an item already in view does not move the page', (t) async {
    _size(t, _desktop);
    final spotlight = AgentSpotlightController();
    addTearDown(spotlight.dispose);
    await t.pumpWidget(_layer(spotlight));
    await t.pumpAndSettle();
    spotlight.focus('room#2');
    await t.pumpAndSettle();
    expect(
      t.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      0,
    );
  });

  testWidgets('"下一批": a screen on, then the top after the end; nothing to '
      'do when all fits', (t) async {
    _size(t, _phone);
    final spotlight = AgentSpotlightController();
    final page = HfPageController();
    addTearDown(spotlight.dispose);
    addTearDown(page.dispose);
    // Enough rows that the end is more than two screens away.
    await t.pumpWidget(_layer(spotlight, rows: 30, page: page));
    await t.pumpAndSettle();
    final view = _viewport(t).height;
    expect(page.nextScreen(), HfPageStep.moved);
    await t.pumpAndSettle();
    expect(page.offset, closeTo(view * .85, 2));
    while (page.offset < page.position.maxScrollExtent - 1) {
      page.nextScreen();
      await t.pumpAndSettle();
    }
    expect(page.nextScreen(), HfPageStep.wrapped);
    await t.pumpAndSettle();
    expect(page.offset, 0);

    await t.pumpWidget(_layer(spotlight, rows: 2, page: HfPageController()));
    await t.pumpAndSettle();
    expect(
      t
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .maxScrollExtent,
      0,
    );
  });

  testWidgets('a stage is whole: no clip, no fade, no cut line', (t) async {
    for (final (size, surface) in [
      (_phone, null),
      (_desktop, null),
      (_tv, HfSurface.tv),
    ]) {
      _size(t, size);
      final spotlight = AgentSpotlightController();
      addTearDown(spotlight.dispose);
      await t.pumpWidget(_layer(spotlight, surface: surface));
      spotlight.focus('room#4');
      await t.pumpAndSettle();
      final detail = find.byKey(const ValueKey('detail'));
      for (final kind in [
        Scrollable,
        ClipRect,
        ClipRRect,
        ClipPath,
        ShaderMask,
      ]) {
        expect(
          find.descendant(of: detail, matching: find.byType(kind)),
          findsNothing,
          reason: '$size $kind',
        );
      }
      for (final p in t.renderObjectList<RenderParagraph>(
        find.descendant(of: detail, matching: find.byType(RichText)),
      )) {
        expect(p.didExceedMaxLines, isFalse, reason: p.text.toPlainText());
      }
      // The whole page has no fades.
      expect(find.byKey(const ValueKey('agent-fade-bottom')), findsNothing);
    }
  });

  testWidgets('a code block wraps and a table shares the width: neither has a '
      'scroll of its own', (t) async {
    _size(t, _phone);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: HandsFree(
            child: HfLayerFrame(
              title: '代码',
              children: [
                HfCodeBlock(
                  code: 'final veryLongName = someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree);',
                ),
                HfTable(
                  columns: const ['一', '二', '三', '四', '五'],
                  rows: [
                    [for (final c in 'abcde'.split('')) AgentTableCell.text(c)],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Scrollable), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
