import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

// raft-ui 0.7.1 `Switch`: 50x30 round track, 22px thumb with its own 1.5px ring; off `fill-muted`, on the `brand`
// sticker, disabled `fill-muted` / `foreground-disabled` (not opacity); the keyboard focus ring.
Widget _app(bool dark, Widget child) => MaterialApp(
  theme: raftTheme(dark: dark),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

List<RaftCssBox> _boxes(WidgetTester tester) => tester
    .widgetList<RaftCssBox>(
      find.descendant(
        of: find.byType(RaftSwitch),
        matching: find.byType(RaftCssBox),
      ),
    )
    .toList();

void main() {
  for (final dark in raftThemeMatrix([false, true])) {
    final mode = dark ? 'dark' : 'light';
    final ui = RaftUiColors.of(dark);

    testWidgets('$mode is 50x30 with a 22px thumb at either size', (
      tester,
    ) async {
      for (final size in RaftSwitchSize.values) {
        await tester.pumpWidget(
          _app(dark, RaftSwitch(value: false, onChanged: (_) {}, size: size)),
        );
        expect(tester.getSize(find.byType(RaftSwitch)), const Size(50, 30));
        final boxes = _boxes(tester);
        expect(boxes[0].radius, 15);
        expect(boxes[1].width, 22);
        expect(boxes[1].radius, 11);
      }
    });

    testWidgets('$mode off, on and disabled colours', (tester) async {
      await tester.pumpWidget(
        _app(dark, RaftSwitch(value: false, onChanged: (_) {})),
      );
      var boxes = _boxes(tester);
      expect(boxes[0].fill, ui.fillMuted);
      expect(boxes[0].borderColor, ui.lineStrong);
      expect(boxes[0].rings, isEmpty);
      expect(boxes[1].fill, ui.layerCard);
      expect(boxes[1].rings.single, RaftRing(1.5, ui.lineStrong));

      await tester.pumpWidget(
        _app(dark, RaftSwitch(value: true, onChanged: (_) {})),
      );
      await tester.pumpAndSettle();
      boxes = _boxes(tester);
      expect(boxes[0].fill, ui.brand);
      expect(boxes[0].borderColor, ui.stickerInk);
      expect(boxes[0].rings.single, RaftRing(1.5, ui.stickerEdge));
      expect(boxes[1].fill, ui.stickerPaper);
      expect(boxes[1].rings.single, RaftRing(1.5, ui.stickerInk));

      for (final on in [false, true]) {
        await tester.pumpWidget(_app(dark, RaftSwitch(value: on)));
        await tester.pumpAndSettle();
        boxes = _boxes(tester);
        final ink = raftChromeBlend(ui.foregroundDisabled, ui.fillMuted);
        expect(boxes[0].fill, ui.fillMuted, reason: 'on=$on');
        expect(boxes[0].borderColor, ink, reason: 'on=$on');
        expect(boxes[1].fill, ui.fillMuted, reason: 'on=$on');
        expect(boxes[1].rings.single.color, ink, reason: 'on=$on');
        expect(find.byType(Opacity), findsNothing);
      }
    });

    testWidgets('$mode the thumb travels 20px when on', (tester) async {
      await tester.pumpWidget(
        _app(dark, RaftSwitch(value: false, onChanged: (_) {})),
      );
      final off = tester.getTopLeft(find.byType(RaftCssBox).last).dx;
      await tester.pumpWidget(
        _app(dark, RaftSwitch(value: true, onChanged: (_) {})),
      );
      await tester.pumpAndSettle();
      final on = tester.getTopLeft(find.byType(RaftCssBox).last).dx;
      expect(on - off, closeTo(20, .01));
    });

    testWidgets('$mode tap toggles, a disabled switch does not', (
      tester,
    ) async {
      final calls = <bool>[];
      await tester.pumpWidget(
        _app(dark, RaftSwitch(value: false, onChanged: calls.add)),
      );
      await tester.tap(find.byType(RaftSwitch));
      expect(calls, [true]);

      calls.clear();
      await tester.pumpWidget(
        _app(
          dark,
          RaftSwitch(value: false, enabled: false, onChanged: calls.add),
        ),
      );
      await tester.tap(find.byType(RaftSwitch), warnIfMissed: false);
      await tester.pumpWidget(_app(dark, const RaftSwitch(value: false)));
      await tester.tap(find.byType(RaftSwitch), warnIfMissed: false);
      expect(calls, isEmpty);
    });

    testWidgets('$mode semantics: toggled, labelled, disabled', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          dark,
          RaftSwitch(
            value: true,
            onChanged: (_) {},
            semanticLabel: 'Notifications',
          ),
        ),
      );
      final node = tester
          .getSemantics(find.bySemanticsLabel('Notifications'))
          .getSemanticsData();
      expect(node.flagsCollection.isToggled, Tristate.isTrue);
      expect(node.flagsCollection.isEnabled, Tristate.isTrue);
      await tester.pumpWidget(
        _app(dark, const RaftSwitch(value: false, semanticLabel: 'Off')),
      );
      final off = tester
          .getSemantics(find.bySemanticsLabel('Off'))
          .getSemanticsData();
      expect(off.flagsCollection.isEnabled, Tristate.isFalse);
      handle.dispose();
    });

    testWidgets(
      '$mode keyboard focus draws the focus ring in place of the sticker ring',
      (tester) async {
        await tester.pumpWidget(
          _app(dark, RaftSwitch(value: true, onChanged: (_) {})),
        );
        await tester.pumpAndSettle();
        expect(_boxes(tester)[0].rings.single.color, ui.stickerEdge);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(_boxes(tester)[0].rings, [
          for (final layer in ui.focusRing.layers)
            RaftRing(layer.spread, layer.color),
        ]);
      },
    );
  }
}
