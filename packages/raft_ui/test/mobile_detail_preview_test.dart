import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/mobile_detail_previews.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final dark in raftThemeMatrix([false, true])) {
    for (final (name, preview) in <(String, Widget Function())>[
      ('dm', mobileDmSettingsPreview),
      ('image', mobileAttachmentImagePreview),
      ('document', mobileAttachmentDocumentPreview),
      ('loading', mobileAttachmentLoadingPreview),
      ('error', mobileAttachmentErrorPreview),
    ]) {
      testWidgets('Mobile preview $name ${dark ? 'dark' : 'light'}', (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final semantics = t.ensureSemantics();
        final capture = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(dark: dark),
            home: Scaffold(
              body: RepaintBoundary(key: capture, child: preview()),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(find.byType(RaftMobilePageHeader), findsNothing);
        {
          // Native-only pages wear Web's phone PanelHeader: h-62 brutal / 56
          // elegant, the boxed PanelAction Back after px-5.
          final back = find.byType(RaftPanelAction);
          expect(t.getSize(back), const Size(32, 32));
          expect(t.getTopLeft(back).dx, 20);
          // Centred in the header's border-box (brutal 62 less its 2px edge).
          expect(t.getCenter(back).dy, 56 / 2);
        }
        final title = name == 'dm'
            ? 'Conversation settings'
            : name == 'document'
            ? 'research.md'
            : '日本語・设计.png';
        expect(
          t.getSemantics(find.text(title)).flagsCollection.isHeader,
          isTrue,
        );
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final render =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File(
            '../../.local/mobile-detail-previews/$name-$dark.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        });
        // The same isolated preview also fits a compact phone viewport.
        t.view.physicalSize = const Size(320, 568);
        await t.pump();
        expect(t.takeException(), isNull);
        if (name == 'dm') {
          expect(find.text('Alice'), findsOneWidget);
          await t.tap(find.byType(RaftSwitch));
          await t.pump();
          expect(t.widget<RaftSwitch>(find.byType(RaftSwitch)).value, isTrue);
          await t.tap(find.byType(RaftPanelAction));
          await t.pump();
          expect(find.text('Open settings'), findsOneWidget);
        } else {
          await t.tap(find.text('Download original'));
          await t.pump();
          expect(find.text('Download requested'), findsOneWidget);
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await t.pump();
          expect(find.text('Open preview'), findsOneWidget);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      });
    }
  }
}
