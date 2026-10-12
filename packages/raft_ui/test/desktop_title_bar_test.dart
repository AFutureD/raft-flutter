import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

/// The desktop title strip: the nav rail's colour with a rail-coloured rule
/// (Brutal: 2 px black; Elegant: 1 px divider), no text, a drag area, and gone
/// in fullscreen.
void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets('$family/$dark strip wears the rail colours and rule', (
      tester,
    ) async {
      final theme = raftTheme(family, dark: dark);
      final tokens = theme.extension<RaftTokens>()!;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const RaftDesktopTitleBar(
            height: 28,
            child: SizedBox.expand(key: Key('content')),
          ),
        ),
      );
      final strip = tester.widget<DecoratedBox>(
        find.byKey(const Key('desktop-title-strip')),
      );
      final decoration = strip.decoration as BoxDecoration;
      final border = decoration.border! as Border;
      final rail = RaftRailRecipe(tokens, viewportHeight: 800);
      expect(decoration.color, rail.background);
      expect(border.bottom.color, rail.border.color);
      expect(border.bottom.width, family == RaftFamily.brutal ? 2 : 1);
      expect(border.top, BorderSide.none);
      expect(border.left, BorderSide.none);
      expect(border.right, BorderSide.none);
      if (family == RaftFamily.brutal) {
        expect(border.bottom.color, Colors.black);
      }
      // Whole strip is the native bar's height; the content gets the rest.
      expect(
        tester.getSize(find.byKey(const Key('desktop-title-strip'))),
        const Size(800, 28),
      );
      final content = tester.getRect(find.byKey(const Key('content')));
      expect(content.top, 28);
      expect(content.height, 600 - 28);
      // No title text, no buttons.
      expect(
        find.descendant(
          of: find.byType(RaftDesktopTitleStrip),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(RaftDesktopTitleStrip),
          matching: find.byType(ButtonStyleButton),
        ),
        findsNothing,
      );
      expect(find.byType(RaftDesktopTitleStrip), findsOneWidget);
    });
  }

  testWidgets('strip follows a live theme change', (tester) async {
    Future<void> pump(RaftFamily family, bool dark) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(family, dark: dark),
          home: const RaftDesktopTitleBar(height: 28, child: SizedBox.expand()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Color colour() =>
        ((tester
                    .widget<DecoratedBox>(
                      find.byKey(const Key('desktop-title-strip')),
                    )
                    .decoration)
                as BoxDecoration)
            .color!;
    await pump(RaftFamily.brutal, false);
    final brutal = colour();
    await pump(RaftFamily.elegant, false);
    final light = colour();
    await pump(RaftFamily.elegant, true);
    final night = colour();
    expect({brutal, light, night}.length, 3);
  });

  testWidgets('drag area starts a window move and double tap is forwarded', (
    tester,
  ) async {
    var drags = 0, doubles = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: RaftDesktopTitleBar(
          height: 28,
          onDragStart: () => drags++,
          onDoubleTap: () => doubles++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final area = find.byKey(const Key('desktop-title-drag'));
    expect(area, findsOneWidget);
    expect(
      tester.widget<GestureDetector>(area).behavior,
      HitTestBehavior.opaque,
    );
    await tester.dragFrom(const Offset(400, 10), const Offset(60, 0));
    expect(drags, 1);
    await tester.tapAt(const Offset(400, 10));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(400, 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(doubles, 1);
    // Content below the strip is not a drag area.
    await tester.dragFrom(const Offset(400, 300), const Offset(60, 0));
    expect(drags, 1);
  });

  testWidgets('no strip in fullscreen or without a native title bar', (
    tester,
  ) async {
    Widget host({required double height, bool fullscreen = false}) =>
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: RaftDesktopTitleBar(
            height: height,
            fullscreen: fullscreen,
            child: const SizedBox.expand(key: Key('content')),
          ),
        );
    await tester.pumpWidget(host(height: 28, fullscreen: true));
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    expect(tester.getRect(find.byKey(const Key('content'))).top, 0);
    await tester.pumpWidget(host(height: 0));
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    await tester.pumpWidget(host(height: 28));
    expect(find.byType(RaftDesktopTitleStrip), findsOneWidget);
    await tester.pumpWidget(host(height: 28, fullscreen: true));
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
  });

  testWidgets('content sees the remaining viewport height', (tester) async {
    double? seen;
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: RaftDesktopTitleBar(
          height: 28,
          child: Builder(
            builder: (context) {
              seen = MediaQuery.sizeOf(context).height;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    expect(seen, 600 - 28);
  });

  testWidgets('strip adds nothing to the semantics tree', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: const RaftDesktopTitleBar(height: 28, child: SizedBox.expand()),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(RaftDesktopTitleStrip),
        matching: find.byType(Semantics),
      ),
      findsNothing,
    );
    semantics.dispose();
  });
}
