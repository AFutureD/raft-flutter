import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/channel_management_previews.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  for (final (family, dark) in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    for (final (name, preview, title) in [
      ('channel', channelSettingsPagePreview, '#general'),
      ('dm', dmSettingsPagePreview, 'Alice'),
    ]) {
      testWidgets('current settings preview $name $family/$dark', (t) async {
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final semantics = t.ensureSemantics();
        final capture = GlobalKey();
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(family, dark: dark),
            home: Scaffold(
              body: RepaintBoundary(key: capture, child: preview()),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.byType(RaftOverflowSheet), findsOneWidget);
        expect(find.byType(RaftChannelSettingsSheet), findsNothing);
        expect(t.getSize(find.byType(RaftMobilePageHeader)).height, 56);
        expect(t.getCenter(find.byType(RaftMobileBackButton)).dx, 32);
        expect(
          t.getSemantics(find.text(title)).flagsCollection.isHeader,
          isTrue,
        );
        expect(t.testTextInput.isVisible, isFalse);
        expect(
          find.byType(RaftChannelInfoForm),
          name == 'channel' ? findsOneWidget : findsNothing,
        );
        expect(t.takeException(), isNull);
        await t.runAsync(() async {
          final render =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File(
            '../../.local/settings-page-previews/$name-${family.name}-$dark.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
        t.view.physicalSize = const Size(320, 568);
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        final toggle = find.byType(RaftSwitch).first;
        await t.ensureVisible(toggle);
        await t.pumpAndSettle();
        await t.tap(toggle);
        await t.pump();
        expect(t.widget<RaftSwitch>(toggle).value, isTrue);
        await t.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      });
    }
  }
}
