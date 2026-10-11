import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/mobile_navigation_previews.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets('Mobile navigation border preview $family/$dark', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final capture = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(family, dark: dark),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: Builder(
                builder: (context) => ColoredBox(
                  color: RaftTokens.of(context).canvas,
                  child: sourceMobileNavigationSystemInsetPreview(),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final nav = t.getRect(find.byType(RaftMobileNav));
      expect(nav.bottom, 810);
      expect(nav.height, family == RaftFamily.brutal ? 55 : 68);
      await t.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final pixels = await image.toByteData();
        Color pixel(int x, int y) {
          final index = (y * image.width + x) * 4;
          return Color.fromARGB(
            pixels!.getUint8(index + 3),
            pixels.getUint8(index),
            pixels.getUint8(index + 1),
            pixels.getUint8(index + 2),
          );
        }

        if (family == RaftFamily.brutal) {
          // Full-width 2px divider at the tab edge, above the 34px system area.
          for (final x in [1, 195, 388]) {
            expect(pixel(x, 808), Colors.black);
            expect(pixel(x, 809), Colors.black);
            expect(pixel(x, 810), Colors.white);
          }
        } else {
          // Elegant remains a centered capsule, without a full-width rule.
          expect(pixel(1, 809), isNot(Colors.black));
        }
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          '../../.local/mobile-tabbar-border/${family.name}-$dark.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      final tasks = family == RaftFamily.brutal
          ? find.widgetWithText(RaftControl, 'Tasks')
          : find.byWidgetPredicate(
              (w) => w is RaftControl && w.semanticLabel == 'Tasks',
            );
      await t.tap(tasks);
      await t.pump();
      expect(
        t.widget<RaftMobileRootHeader>(find.byType(RaftMobileRootHeader)).title,
        'Tasks',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
}
