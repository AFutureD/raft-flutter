import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_list.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_surface.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_orb_driving_summary_test.dart'
    show recentList, resultsList, summaryList;
import 'agent_orb_driving_surface_test.dart' show unread;

/// Renders the driving surfaces (recent, results, summary, "就这些", the
/// unread list and a detail) on the black scrim, one tall phone-size picture
/// per theme, into $RAFT_RENDER_DIR; skipped when it is not set.
void main() {
  final dir = Platform.environment['RAFT_RENDER_DIR'];
  const width = 412.0, ratio = 2.0;

  Future<void> loadCjk() async {
    for (final f in ['HankenGrotesk', 'Geist', 'GeistMono', 'Inter']) {
      final data = ['', '../../']
          .map((up) => File('${up}packages/raft_ui/assets/fonts/$f.ttf'))
          .firstWhere((file) => file.existsSync())
          .readAsBytesSync();
      await (FontLoader(
        'packages/raft_ui/$f',
      )..addFont(Future.value(ByteData.sublistView(data)))).load();
    }
    final bytes = File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
        .readAsBytesSync();
    for (final family in ['Noto Sans CJK JP', 'Noto Sans CJK SC']) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  }

  Widget caption(String text) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(
        // ds-allow: a label on a render for reading, not shipped UI
        color: Color(0xFFFFD60A),
        fontSize: 12,
        fontFamilyFallback: ['Noto Sans CJK SC'],
      ),
    ),
  );

  Future<void> render(
    WidgetTester t,
    ThemeData theme,
    String name,
    double height,
  ) async {
    final boundary = GlobalKey();
    t.view.physicalSize = Size(width, height) * ratio;
    t.view.devicePixelRatio = ratio;
    addTearDown(t.view.reset);

    final spoken = OrbDrivingSurface()..showList(recentList());
    final results = OrbDrivingSurface()..showList(resultsList());
    final summary = OrbDrivingSurface()
      ..showList(summaryList())
      ..spotlight(1);
    final list = OrbDrivingSurface()..showList(unread(7, routine: 5));
    final detail = OrbDrivingSurface()
      ..showList(unread(7, routine: 5))
      ..openRow(1);

    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  caption('a. 最近动态，第 1 行在说'),
                  OrbDrivingList(surface: spoken, onOpenRow: (_) {}),
                  caption('b. 找到（频道、私信、人）'),
                  OrbDrivingList(surface: results, onOpenRow: (_) {}),
                  caption('c. 摘要，第 2 句在说，第 3 句被截'),
                  OrbDrivingSummary(surface: summary),
                  caption('d. 就这些，一件都没有'),
                  const OrbDrivingDone(routineCount: 2, nothing: true),
                  caption('e. 未读 7（对照）'),
                  OrbDrivingList(surface: list, onOpenRow: (_) {}),
                  caption('e. 详情（对照）'),
                  OrbDrivingDetail(
                    surface: detail,
                    onPrimary: () {},
                    onLater: () {},
                    onNext: () {},
                    primaryLabel: '回复',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await t.runAsync(() async {
      final image = await render.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name').writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('the driving surfaces, light and dark', (t) async {
    await t.runAsync(loadCjk);
    await render(
      t,
      raftTheme(RaftFamily.brutal),
      'driving-surfaces-light.png',
      2500,
    );
    await render(
      t,
      raftTheme(RaftFamily.elegant, dark: true),
      'driving-surfaces-dark.png',
      2500,
    );
  }, skip: dir == null);
}
