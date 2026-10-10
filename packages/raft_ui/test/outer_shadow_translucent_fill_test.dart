import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/src/css_recipe_decoration.dart';

import 'control_transition_paint_test.dart' show pixel;

/// CSS clips an outer `box-shadow` to outside the border box; Flutter paints
/// a BoxShadow as a full shape beneath the box, so a translucent or
/// transparent fill would composite over a solid shadow. These assert the
/// interior stays "fill over page background" while the shadow still paints
/// outside.
void main() {
  const page = Color(0xffffffff);

  Widget host(Widget child, {RaftFamily family = RaftFamily.brutal}) =>
      MaterialApp(
        theme: raftTheme(family),
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: const ValueKey('paint'),
            child: ColoredBox(
              color: page,
              child: Padding(padding: const EdgeInsets.all(8), child: child),
            ),
          ),
        ),
      );

  void expectClose(Color actual, Color expected) {
    for (final (a, e) in [
      (actual.r, expected.r),
      (actual.g, expected.g),
      (actual.b, expected.b),
    ]) {
      expect((a - e).abs() * 255, lessThanOrEqualTo(1.5), reason: '$actual');
    }
  }

  testWidgets('brutal highlighted message row is cyan@.25 over the page', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 320,
          child: RaftMessageRow(
            author: 'Cindy',
            timestamp: '00:27',
            highlighted: true,
            content: const SizedBox(height: 60),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tokens = RaftTokens.of(tester.element(find.byType(RaftMessageRow)));
    final cyan = tokens.colors['color-brutal-cyan']!;
    // The decorated box is the row minus its margin.
    final decorated = find.byWidgetPredicate(
      (w) => w is DecoratedBox && w.decoration is RaftCssBoxDecoration,
    );
    final rect = tester
        .getRect(decorated.first)
        .shift(-tester.getTopLeft(find.byKey(const ValueKey('paint'))));
    // Interior, right side, below the header: no text or avatar.
    expectClose(
      await pixel(tester, rect.bottomRight + const Offset(-30, -20)),
      Color.alphaBlend(cyan.withValues(alpha: .25), page),
    );
    // The 4px black offset shadow still paints outside the box.
    final shadow = await pixel(tester, rect.bottomRight + const Offset(-20, 2));
    expect(shadow.computeLuminance(), lessThan(.02), reason: '$shadow');
  });

  testWidgets(
    'RaftRecipeDecoration keeps its shadow out of a translucent fill',
    (tester) async {
      await tester.pumpWidget(
        host(
          DecoratedBox(
            decoration: RaftRecipeDecoration(
              color: const Color(0x4000b4d8),
              boxShadow: const [BoxShadow(offset: Offset(4, 4))],
            ),
            child: const SizedBox(width: 60, height: 40),
          ),
        ),
      );
      expectClose(
        await pixel(tester, const Offset(8 + 30, 8 + 20)),
        Color.alphaBlend(const Color(0x4000b4d8), page),
      );
      expect(await pixel(tester, const Offset(8 + 40, 8 + 42)), Colors.black);
    },
  );

  testWidgets('RaftFieldSurface shadow does not fill its transparent box', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const RaftFieldSurface(child: SizedBox(width: 80, height: 40))),
    );
    final box = tester.getTopLeft(find.byType(RaftFieldSurface));
    // Nothing is painted inside the box; the brutal shadow sits below it.
    expect(await pixel(tester, box + const Offset(40, 20)), page);
    expect(await pixel(tester, box + const Offset(40, 41)), isNot(page));
  });
}
