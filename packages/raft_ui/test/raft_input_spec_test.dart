import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

// raft-ui 0.7.1 `Input`: 44px, `px-3`, 16/24 field text, `rounded-control border-[1.5px] border-line-strong
// bg-layer-card`, invalid `border-danger-strong`, `focus:shadow-focus`, disabled `fill-muted` / `line-hairline`.
Widget _app(bool dark, Widget child, {double width = 358}) => MaterialApp(
  theme: raftTheme(dark: dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: child),
    ),
  ),
);

RaftCssBox _box(WidgetTester tester) => tester.widget<RaftCssBox>(
  find.descendant(
    of: find.byType(RaftTextInput),
    matching: find.byType(RaftCssBox),
  ),
);

void main() {
  for (final dark in raftThemeMatrix([false, true])) {
    final mode = dark ? 'dark' : 'light';
    final ui = RaftUiColors.of(dark);

    testWidgets(
      '$mode is 44px tall, full width, with 12px sides and 8px corners',
      (tester) async {
        await tester.pumpWidget(
          _app(dark, const RaftTextInput(hintText: 'you@example.com')),
        );
        expect(tester.getSize(find.byType(RaftTextInput)), const Size(358, 44));
        final box = _box(tester);
        expect(box.radius, 8);
        expect(box.padding, const EdgeInsets.symmetric(horizontal: 12));
        expect(box.fill, ui.layerCard);
        expect(box.borderColor, ui.lineStrong);
        expect(box.rings, isEmpty);
        expect(find.byType(Opacity), findsNothing);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.style!.fontSize, 16);
        expect(field.style!.height, 24 / 16);
        expect(field.style!.fontWeight, FontWeight.w400);
        expect(field.style!.color, ui.foreground);
        expect(field.decoration!.hintStyle!.color, ui.foregroundHint);
        // The 24px line sits centred in the 44px box.
        final line = tester.getRect(find.byType(EditableText));
        expect((line.center.dy - 22).abs(), lessThan(1));
      },
    );

    testWidgets('$mode a padding override lets the height follow the content', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          dark,
          const RaftTextInput(padding: EdgeInsets.all(8), initialValue: 'x'),
        ),
      );
      expect(tester.getSize(find.byType(RaftTextInput)).height, lessThan(44));
      expect(
        tester.getSize(find.byType(RaftTextInput)).height,
        greaterThanOrEqualTo(24 + 16),
      );
    });

    testWidgets('$mode invalid swaps the border to danger-strong', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          dark,
          const RaftTextInput(initialValue: 'not-an-email', invalid: true),
        ),
      );
      expect(_box(tester).borderColor, ui['danger-strong']);
      expect(_box(tester).fill, ui.layerCard);
    });

    testWidgets(
      '$mode disabled reads fill-muted / line-hairline / foreground-disabled',
      (tester) async {
        await tester.pumpWidget(
          _app(
            dark,
            const RaftTextInput(
              initialValue: 'mia@botiverse.build',
              hintText: 'h',
              enabled: false,
            ),
          ),
        );
        final box = _box(tester);
        expect(box.fill, ui.fillMuted);
        expect(box.borderColor, raftChromeBlend(ui.lineHairline, ui.fillMuted));
        final ink = raftChromeBlend(ui.foregroundDisabled, ui.fillMuted);
        expect(
          tester.widget<TextField>(find.byType(TextField)).style!.color,
          ink,
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .decoration!
              .hintStyle!
              .color,
          ink,
        );
        expect(find.byType(Opacity), findsNothing);
        await tester.enterText(find.byType(TextField), 'nope');
        expect(find.text('mia@botiverse.build'), findsOneWidget);
      },
    );

    testWidgets(
      '$mode focus draws the focus ring and keeps the field mounted',
      (tester) async {
        final changes = <String>[];
        await tester.pumpWidget(
          _app(dark, RaftTextInput(onChanged: changes.add)),
        );
        expect(_box(tester).rings, isEmpty);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        expect(_box(tester).rings, [
          for (final layer in ui.focusRing.layers)
            RaftRing(layer.spread, layer.color),
        ]);
        await tester.enterText(find.byType(TextField), 'hello');
        expect(changes, ['hello']);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(tester.getSize(find.byType(RaftTextInput)).height, 44);
      },
    );

    testWidgets(
      '$mode the Material-hosted field keeps its border on focus and draws the ring outside',
      (tester) async {
        await tester.pumpWidget(
          _app(
            dark,
            const RaftFieldSurface(
              child: TextField(decoration: InputDecoration(hintText: 'Name')),
            ),
          ),
        );
        final theme = Theme.of(tester.element(find.byType(TextField)));
        final border =
            theme.inputDecorationTheme.enabledBorder! as OutlineInputBorder;
        expect(border.borderRadius, BorderRadius.circular(8));
        expect(border.borderSide.color, ui.lineStrong);
        expect(border.borderSide.width, 1.5);
        expect(
          (theme.inputDecorationTheme.disabledBorder! as OutlineInputBorder)
              .borderSide
              .color,
          ui.lineHairline,
        );
        expect(
          (theme.inputDecorationTheme.errorBorder! as OutlineInputBorder)
              .borderSide
              .color,
          ui['danger-strong'],
        );
        expect(theme.inputDecorationTheme.fillColor, isNotNull);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        final rings = tester.widget<RaftOuterRings>(
          find.byType(RaftOuterRings),
        );
        expect(rings.rings.length, ui.focusRing.layers.length);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .focusNode
              .hasFocus,
          isTrue,
        );
      },
    );
  }
}
