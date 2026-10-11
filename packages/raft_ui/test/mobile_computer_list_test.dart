import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

import 'task_typography_test.dart' show loadTaskFonts;

void main() {
  for (final (family, dark) in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    testWidgets(
      'mobile computer cards preserve cached states and activate $family/$dark',
      (t) async {
        await loadTaskFonts(t);
        t.view.physicalSize = const Size(390, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final semantics = t.ensureSemantics();
        try {
          var opened = 0, added = 0, retried = 0;
          final capture = GlobalKey();
          Future<void> mount({
            bool loading = false,
            bool rows = true,
            String? error,
            double scale = 1,
          }) => t.pumpWidget(
            MaterialApp(
              theme: raftTheme(family, dark: dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: RepaintBoundary(
                  key: capture,
                  child: Column(
                    children: [
                      const RaftMobilePageHeader(title: Text('Computers')),
                      Expanded(
                        child: RaftMobileComputerList(
                          loading: loading,
                          error: error,
                          emptyTitle: 'No computers yet',
                          emptyDetail:
                              'Add a computer to run agents in this workspace.',
                          addLabel: 'Add computer',
                          retryLabel: 'Retry',
                          onAdd: () => added++,
                          onRetry: () => retried++,
                          rows: rows
                              ? [
                                  RaftComputerRow(
                                    key: const Key('computer-card'),
                                    mobile: true,
                                    name: 'Build Computer',
                                    description: 'Shared development machine',
                                    runLabel: 'Computer v1.0.44',
                                    offline: false,
                                    dot: RaftComputerDot.upgrade,
                                    availableVersion: '1.0.45',
                                    diskLow: true,
                                    onTap: () => opened++,
                                  ),
                                ]
                              : [],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await mount();
          final card = find.byKey(const Key('computer-card'));
          expect(t.getRect(card).left, 16);
          expect(t.getRect(card).right, 374);
          expect(t.getSize(card).height, greaterThanOrEqualTo(68));
          expect(find.text('Computers'), findsOneWidget);
          expect(find.text('→ v1.0.45'), findsOneWidget);
          expect(find.text('Low disk'), findsOneWidget);
          expect(t.getSemantics(card).flagsCollection.isButton, true);
          await t.tap(card);
          await t.sendKeyEvent(LogicalKeyboardKey.enter);
          expect(opened, 2);
          await t.tap(find.byKey(const ValueKey('computers-add-row')));
          expect(added, 1);
          final evidence = Platform.environment['RAFT_COMPUTER_EVIDENCE_DIR'];
          if (evidence != null) {
            await t.pump();
            await t.runAsync(() async {
              final image =
                  await (capture.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('$evidence/${family.name}-$dark.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await mount(loading: true);
          expect(card, findsOneWidget);
          expect(find.byType(RaftSkeletonRow), findsNothing);
          await mount(error: 'Refresh failed');
          expect(card, findsOneWidget);
          await t.tap(find.text('Retry'));
          expect(retried, 1);
          await mount(loading: true, rows: false);
          expect(find.byType(RaftSkeletonRow), findsNWidgets(4));
          expect(find.byKey(const ValueKey('computers-add-row')), findsNothing);
          await mount(rows: false);
          expect(find.text('No computers yet'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('computers-add-row')),
            findsOneWidget,
          );
          t.view.physicalSize = const Size(280, 844);
          await mount(scale: 2);
          await t.pump();
          expect(card, findsOneWidget);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );
  }
}
