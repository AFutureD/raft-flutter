import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

// Actual original mounted ThreadPanel safe-point samples, all six contexts:
// reports/thread-header-border-source-20261009/receipt.json and
// reports/ink10-browser-paint-diagnostic-20261009/receipt.json.
void main() {
  for (final width in [390.0, 957.0]) {
    for (final dark in raftThemeMatrix([false, true])) {
      testWidgets(
        'mounted header rule paint $width/${dark ? 'dark' : 'light'}',
        (t) async {
          final key = GlobalKey();
          await t.binding.setSurfaceSize(Size(width, 100));
          addTearDown(() => t.binding.setSurfaceSize(null));
          await t.pumpWidget(
            MaterialApp(
              theme: raftTheme(dark: dark),
              home: RepaintBoundary(
                key: key,
                child: RaftConversationSurface(
                  role: RaftConversationSurfaceRole.threadTimeline,
                  child: Column(
                    children: [
                      RaftThreadHeader(
                        presentation: RaftThreadPresentation.side,
                        viewportWidth: width,
                        viewportHeight: 720,
                        threadLabel: 'Thread',
                        jumpLabel: 'First message',
                        backLabel: 'Back',
                        closeLabel: 'Close',
                      ),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ),
              ),
            ),
          );
          await t.pump();
          final header = find.byType(RaftThreadHeader);
          // `--shell-header-height`: 56 at every width (the
          // phone header is Web's PanelHeader, not a shared 56px page header).
          final height = 56;
          expect(t.getSize(header).height, height);
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await t.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              List<int> rgb(int y) => [
                for (var c = 0; c < 3; c++)
                  data.getUint8((y * image.width + 200) * 4 + c),
              ];
              // Rule is line-hairline (ink 15% / paper 10%) over the header
              // fill: sidebar on phones, canvas from 768.
              final expected = !dark
                  ? width < 768
                        ? [220, 215, 206]
                        : [220, 220, 220]
                  : width < 768
                  ? [37, 37, 35]
                  : [58, 58, 56];
              expect(rgb(height - 1), expected);
              expect(
                rgb(height - 2),
                dark
                    ? width < 768
                          ? [13, 13, 11]
                          : [36, 36, 34]
                    : width < 768
                    ? [255, 250, 239]
                    : [255, 255, 255],
              );
            } finally {
              image.dispose();
            }
          });
          await t.pumpWidget(const SizedBox());
          expect(t.takeException(), isNull);
        },
      );
    }
  }
}
