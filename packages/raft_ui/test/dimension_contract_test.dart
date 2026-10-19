import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  test(
    'sidebar directional geometry keeps overlay and in-flow headers distinct',
    () {
      final elegant = raftTheme().extension<RaftTokens>()!;
      final desktop = RaftSidebarRecipe(
        elegant,
        viewportWidth: 1024,
        viewportHeight: 844,
      );
      expect(
        desktop.headerInset,
        const EdgeInsetsDirectional.only(start: 26, end: 18),
      );
      expect(
        desktop.contentInset(),
        const EdgeInsetsDirectional.fromSTEB(26, 56, 18, 12),
      );
      expect(desktop.contentInset(headerInFlow: true).top, 0);
      expect(desktop.contentInset().bottom, 12);
      final shortMobile = RaftSidebarRecipe(
        elegant,
        viewportWidth: 390,
        viewportHeight: 560,
      );
      expect(
        shortMobile.headerInset,
        const EdgeInsetsDirectional.symmetric(horizontal: 28),
      );
      expect(
        shortMobile.contentInset(),
        const EdgeInsetsDirectional.fromSTEB(28, 48, 28, 12),
      );
    },
  );
  test(
    'rail keeps source theme glyph and compact face dimensions separate',
    () {
      final elegant = RaftRailRecipe(
        raftTheme().extension<RaftTokens>()!,
        viewportHeight: 560,
      );
      expect(elegant.glyphSize, 16);
      expect(elegant.itemSize, 40);
      expect(elegant.width, 56);
    },
  );
  test('mounted product sidebar overrides library geometry and reserves actual mobile overlay', () {
    final t = raftTheme().extension<RaftTokens>()!;
    final desktop = RaftSidebarRecipe(
      t,
      viewportWidth: 1024,
      viewportHeight: 844,
      variant: RaftSidebarVariant.mountedProduct,
    );
    expect(desktop.headerOverlaysContent, false);
    expect(
      desktop.headerInset,
      const EdgeInsetsDirectional.symmetric(horizontal: 20),
    );
    expect(
      desktop.contentInset(),
      const EdgeInsetsDirectional.fromSTEB(8, 12, 8, 12),
    );
    expect(desktop.contentInset(headerInFlow: true), desktop.contentInset());
    final workspace = RaftSidebarRecipe(
      t,
      viewportWidth: 1024,
      viewportHeight: 844,
      variant: RaftSidebarVariant.mountedProduct,
      workspaceEnabled: true,
    );
    expect(workspace.headerHeight, 48);
    expect(workspace.headerInset.start, 16);
    final mobile = RaftSidebarRecipe(
      t,
      viewportWidth: 390,
      viewportHeight: 844,
      variant: RaftSidebarVariant.mountedProduct,
    );
    expect(mobile.headerInset.start, 16);
    expect(mobile.contentInset().bottom, 68);
    // Nothing is attached above the tab bar: clearance is the capsule only.
    expect(mobile.contentInset(bottomInset: 24).bottom, 92);
  });
  test(
    'sidebar uses the source body role across theme and responsive variants',
    () {
      for (final (dark, mobile, expected) in raftThemeMatrix([
        (false, true, RaftTokenSet.light.colors.layerCanvasMuted),
        (true, true, const Color(0xff0d0d0b)),
        (true, false, const Color(0xff0d0d0b)),
      ], full: true)) {
        final t = raftTheme(dark: dark).extension<RaftTokens>()!;
        for (final variant in RaftSidebarVariant.values) {
          final r = RaftSidebarRecipe(
            t,
            viewportWidth: mobile ? 390 : 1024,
            viewportHeight: 844,
            variant: variant,
          );
          expect(r.bodyBackground, expected);
        }
      }
    },
  );
  testWidgets('constrained segmented options wrap and retain keyboard order', (
    tester,
  ) async {
    var value = 'small';
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(),
        home: Scaffold(
          body: RaftDensityScope(
            density: RaftDensity.desktop,
            child: StatefulBuilder(
              builder: (context, update) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 150,
                  child: RaftSegmentedControl(
                    label: 'Font size',
                    value: value,
                    visualHeight: 32,
                    style: RaftSegmentedStyle.buttons,
                    onChanged: (next) => update(() => value = next),
                    items: const [
                      RaftSegmentedOption(value: 'small', label: 'Small'),
                      RaftSegmentedOption(value: 'medium', label: 'Medium'),
                      RaftSegmentedOption(value: 'large', label: 'Large'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // segmentedControl items.
    final controls = find.byType(RaftSegmentedItem);
    expect(controls, findsNWidgets(3));
    expect(
      tester.getTopLeft(controls.last).dy,
      greaterThan(tester.getTopLeft(controls.first).dy),
    );
    for (var index = 0; index < 3; index++) {
      expect(tester.getRect(controls.at(index)).right, lessThanOrEqualTo(150));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(value, 'medium');
    await tester.tap(find.text('Large'));
    expect(value, 'large');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
