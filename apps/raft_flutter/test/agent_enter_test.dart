import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// The entrance of pieces that appear while the agent talks: turns handed out
/// by the pacer, the staged parts of one piece, reduced motion, and that the
/// final layout is reserved from the first frame.
void main() {
  group('pacer', () {
    AgentEnterPacer pacer(Duration Function() clock) => AgentEnterPacer(
      base: const Duration(milliseconds: 360),
      maxLag: const Duration(milliseconds: 400),
      clock: clock,
    );

    test('a piece on its own starts at once, with its full motion', () {
      final p = pacer(() => Duration.zero);
      final plan = p.plan(1).single;
      expect(plan.delay, Duration.zero);
      expect(plan.duration, const Duration(milliseconds: 360));
    });

    test('siblings are staggered in order, each at 60% of the previous', () {
      final p = pacer(() => Duration.zero);
      final plans = p.plan(2);
      expect(plans[0].delay, Duration.zero);
      // 60% of 360 ms.
      expect(plans[1].delay, const Duration(milliseconds: 216));
      expect(plans[0].duration, plans[1].duration);
    });

    test('a piece that arrives while one is still entering waits its turn', () {
      var now = Duration.zero;
      final p = pacer(() => now);
      p.plan(1);
      now = const Duration(milliseconds: 100);
      // The first started at 0, so the next may start at 216 ms: 116 ms from
      // now.
      expect(p.plan(1).single.delay, const Duration(milliseconds: 116));
      // Long after, nothing is in the way.
      now = const Duration(seconds: 5);
      expect(p.plan(1).single.delay, Duration.zero);
    });

    test('a burst catches up: never more than 400 ms behind arrival', () {
      final p = pacer(() => Duration.zero);
      final plans = p.plan(12);
      expect(plans.first.delay, Duration.zero);
      for (var i = 1; i < plans.length; i++) {
        // Strictly one after another, not dumped together.
        expect(plans[i].delay, greaterThan(plans[i - 1].delay));
      }
      expect(
        plans.last.delay,
        lessThanOrEqualTo(const Duration(milliseconds: 400)),
      );
      // Squeezed pieces also move faster.
      expect(plans.first.duration, lessThan(const Duration(milliseconds: 360)));
      expect(
        plans.first.duration,
        greaterThanOrEqualTo(const Duration(milliseconds: 144)),
      );
    });

    test('a sustained stream never falls further behind than the lag', () {
      var now = Duration.zero;
      final p = pacer(() => now);
      var worst = Duration.zero;
      // Eight pieces every 50 ms for a second.
      for (var i = 0; i < 20; i++) {
        final plans = p.plan(8);
        for (final plan in plans) {
          if (plan.delay > worst) worst = plan.delay;
        }
        now += const Duration(milliseconds: 50);
      }
      expect(worst, lessThanOrEqualTo(const Duration(milliseconds: 400)));
    });
  });

  Widget app(Widget child, {bool reduced = false}) => MaterialApp(
    theme: raftTheme(RaftFamily.brutal),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: Center(child: child)),
    ),
  );

  Widget piece({AgentEnterPacer? pacer}) {
    final body = AgentAppear(
      child: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AgentTypeText(
              '修复搜索打开频道后无法返回，并补上回归测试',
              maxLines: 2,
              style: TextStyle(fontSize: 18),
            ),
            const AgentCountUp('128', style: TextStyle(fontSize: 30)),
            AgentPop(
              child: Container(
                key: const ValueKey('chip'),
                width: 60,
                height: 20,
                color: Colors.red,
              ),
            ),
          ],
        ),
      ),
    );
    return pacer == null ? body : AgentEnterPacing(pacer: pacer, child: body);
  }

  const headline = '修复搜索打开频道后无法返回，并补上回归测试';

  testWidgets('the final size is reserved from the first frame', (t) async {
    await t.pumpWidget(app(piece()));
    final first = t.getSize(find.byType(Column).last);
    final partsFirst = [
      for (final f in [
        find.byType(AgentTypeText),
        find.byType(AgentCountUp),
        find.byType(AgentPop),
      ])
        t.getSize(f),
    ];
    // Mid-entrance, the same.
    await t.pump(const Duration(milliseconds: 150));
    expect(t.getSize(find.byType(Column).last), first);
    await t.pumpAndSettle();
    expect(t.getSize(find.byType(Column).last), first);
    // The parts pop and type, but their layout boxes never change.
    expect([
      for (final f in [
        find.byType(AgentTypeText),
        find.byType(AgentCountUp),
        find.byType(AgentPop),
      ])
        t.getSize(f),
    ], partsFirst);
    expect(find.text(headline), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
  });

  testWidgets('the piece enters in stages: container, text, then parts', (
    t,
  ) async {
    await t.pumpWidget(app(piece()));
    double opacity() => t
        .widgetList<Opacity>(
          find.ancestor(
            of: find.byKey(const ValueKey('chip')),
            matching: find.byType(Opacity),
          ),
        )
        .map((o) => o.opacity)
        .reduce((a, b) => a < b ? a : b);
    String typed() {
      final text = t.widget<Text>(find.byType(Text).first);
      final span = text.textSpan as TextSpan?;
      return span?.text ?? text.data ?? '';
    }

    // Right after the first frame the container has barely started: the
    // text has not begun and the chip is not there yet.
    await t.pump(const Duration(milliseconds: 20));
    expect(typed(), isEmpty);
    expect(opacity(), 0);
    // Container settled enough: the headline types, characters first.
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    final part = typed();
    expect(part, isNotEmpty);
    expect(part.length, lessThan(headline.length));
    expect(headline.startsWith(part), isTrue);
    // The chip pops in last.
    await t.pumpAndSettle();
    expect(typed(), headline);
    expect(opacity(), 1);
  });

  testWidgets('numbers count up and end on the real value', (t) async {
    await t.pumpWidget(app(piece()));
    await t.pump(const Duration(milliseconds: 20));
    String shown() {
      final w = t.widget<Text>(
        find.byWidgetPredicate((w) => w is Text && (w.style?.fontSize == 30)),
      );
      return (w.textSpan as TextSpan?)?.toPlainText() ?? w.data ?? '';
    }

    expect(shown().length, 3); // reserved: three digits from the start
    await t.pump(const Duration(milliseconds: 260));
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpAndSettle();
    expect(shown(), '128');
  });

  testWidgets('pieces of a burst enter one after another', (t) async {
    final pacer = AgentEnterPacer(clock: () => Duration.zero);
    double opacityOf(Key key) => t
        .widget<Opacity>(
          find
              .ancestor(of: find.byKey(key), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    await t.pumpWidget(
      app(
        AgentEnterPacing(
          pacer: pacer,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                AgentAppear(
                  child: SizedBox(key: ValueKey('p$i'), width: 80, height: 40),
                ),
            ],
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 100));
    // The first is on its way, the later ones have not started.
    expect(opacityOf(const ValueKey('p0')), greaterThan(0));
    expect(opacityOf(const ValueKey('p2')), 0);
    await t.pump(const Duration(milliseconds: 350));
    expect(opacityOf(const ValueKey('p1')), greaterThan(0));
    await t.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      expect(opacityOf(ValueKey('p$i')), 1);
    }
  });

  testWidgets('reduced motion: everything is simply there', (t) async {
    await t.pumpWidget(app(piece(), reduced: true));
    // First frame, no waiting: full text, final number, chip visible.
    expect(find.text(headline), findsOneWidget);
    expect(find.text('128'), findsOneWidget);
    for (final o in t.widgetList<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('chip')),
        matching: find.byType(Opacity),
      ),
    )) {
      expect(o.opacity, 1);
    }
  });

  testWidgets('text waits for the speaker while held, then types', (t) async {
    final sync = AgentRevealSync()..hold('item#1');
    addTearDown(sync.dispose);
    await t.pumpWidget(
      app(
        AgentRevealSyncScope(
          sync: sync,
          child: AgentAppear(
            child: AgentItemScope(
              id: 'item#1',
              child: const SizedBox(
                width: 300,
                child: AgentTypeText(headline, style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
        ),
      ),
    );
    final size = t.getSize(find.byType(AgentTypeText));
    await t.pump(const Duration(seconds: 2));
    var text = t.widget<Text>(find.byType(Text));
    // The container has long finished but the words were not spoken yet.
    expect((text.textSpan as TextSpan).text, isEmpty);
    expect(t.getSize(find.byType(AgentTypeText)), size);
    sync.release('item#1');
    await t.pump();
    await t.pump(const Duration(milliseconds: 150));
    text = t.widget<Text>(find.byType(Text));
    expect((text.textSpan as TextSpan).text, isNotEmpty);
    await t.pumpAndSettle();
    expect(find.text(headline), findsOneWidget);
  });
}
