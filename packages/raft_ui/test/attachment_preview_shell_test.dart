import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  for (final family in RaftFamily.values) {
    testWidgets('$family wide shell: comments toggle opens the 320px aside', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(family),
          home: RaftAttachmentPreviewShell(
            filename: 'notes.txt',
            onClose: () {},
            copyText: 'hello',
            commentsBuilder: (_, sheet) {
              expect(sheet, isNull);
              return const Text('panel');
            },
            child: const Text('body'),
          ),
        ),
      );
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('TXT'), findsOneWidget);
      expect(find.text('panel'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('attachment-preview-mode')));
      await tester.pumpAndSettle();
      expect(find.text('panel'), findsOneWidget);
      expect(
        tester.getSize(find.ancestor(of: find.text('panel'), matching: find.byType(RaftLightboxAside))).width,
        raftLightboxAsideWidth,
      );
    });

    testWidgets('$family narrow shell: the sheet starts collapsed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      RaftCommentsSheetControls? seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(family),
          home: RaftAttachmentPreviewShell(
            filename: 'notes.txt',
            onClose: () {},
            commentsBuilder: (_, sheet) {
              seen = sheet;
              return const SizedBox();
            },
            child: const Text('body'),
          ),
        ),
      );
      expect(seen, isNotNull);
      expect(seen!.expanded, isFalse);
    });
  }
}
