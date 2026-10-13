import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/desktop_title_bar.dart';
import 'package:raft_ui/raft_ui.dart';
import 'flutter_test_config.dart' show leakDebt;

/// A runner stand-in on `app.raft/titlebar`: records what the app sends and
/// can push `state` the way the macOS runner does on resize / fullscreen.
class _Runner {
  _Runner(this.tester, {this.height = 28}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'status') {
        return {'height': height, 'fullscreen': fullscreen};
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
  }

  final WidgetTester tester;
  final channel = const MethodChannel(DesktopTitleBarController.channelName);
  final calls = <MethodCall>[];
  double height;
  bool fullscreen = false;

  List<MethodCall> named(String method) => [
    for (final call in calls)
      if (call.method == method) call,
  ];

  Future<void> push({double? height, bool? fullscreen}) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('state', {
          'height': height ?? this.height,
          'fullscreen': fullscreen ?? this.fullscreen,
        }),
      ),
      (_) {},
    );
    await tester.pump();
  }
}

Widget _app(
  DesktopTitleBarController controller, {
  RaftFamily family = RaftFamily.elegant,
  bool dark = false,
  Widget child = const SizedBox.expand(key: Key('content')),
}) => MaterialApp(
  theme: raftTheme(family, dark: dark),
  home: RepaintBoundary(
    key: const Key('titlebar-surface'),
    child: DesktopTitleBar(controller: controller, child: child),
  ),
);

void main() {
  // Leak debt (other): see docs/development.md, Leak tracking.
  leakDebt(const ['ValueNotifier<DesktopTitleBarState>']);
  testWidgets('macOS: strip at the reported height, content below it', (
    tester,
  ) async {
    final runner = _Runner(tester, height: 32);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.macOS,
      web: false,
    );
    await tester.pumpWidget(_app(controller));
    await tester.pump();
    expect(find.byType(RaftDesktopTitleStrip), findsOneWidget);
    expect(tester.getSize(find.byType(RaftDesktopTitleStrip)).height, 32);
    expect(tester.getRect(find.byKey(const Key('content'))).top, 32);
    expect(runner.named('status'), hasLength(1));
  });

  testWidgets('macOS: fullscreen removes the strip, leaving fullscreen '
      'brings it back', (tester) async {
    final runner = _Runner(tester);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.macOS,
      web: false,
    );
    await tester.pumpWidget(_app(controller));
    await tester.pump();
    expect(find.byType(RaftDesktopTitleStrip), findsOneWidget);
    // The runner reports zero height and fullscreen together.
    await runner.push(height: 0, fullscreen: true);
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    expect(tester.getRect(find.byKey(const Key('content'))).top, 0);
    // A stale height is not enough to draw an empty strip in fullscreen.
    await runner.push(height: 28, fullscreen: true);
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    await runner.push(height: 28, fullscreen: false);
    expect(find.byType(RaftDesktopTitleStrip), findsOneWidget);
  });

  testWidgets('macOS: drag and double tap reach the runner', (tester) async {
    final runner = _Runner(tester);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.macOS,
      web: false,
    );
    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.dragFrom(const Offset(400, 10), const Offset(50, 0));
    expect(runner.named('startDragging'), hasLength(1));
    await tester.tapAt(const Offset(400, 10));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(400, 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(runner.named('doubleClick'), hasLength(1));
  });

  testWidgets('every theme sends the rail colours, once per change', (
    tester,
  ) async {
    final runner = _Runner(tester);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.macOS,
      web: false,
    );
    for (final (family, dark) in [
      (RaftFamily.brutal, false),
      (RaftFamily.elegant, false),
      (RaftFamily.elegant, true),
    ]) {
      await tester.pumpWidget(_app(controller, family: family, dark: dark));
      await tester.pumpAndSettle();
      final tokens = raftTheme(family, dark: dark).extension<RaftTokens>()!;
      final rail = RaftRailRecipe(tokens, viewportHeight: 800);
      final sent = runner.named('setStyle').last.arguments as Map;
      expect(sent['background'], rail.background.toARGB32());
      expect(
        sent['rule'],
        Color.alphaBlend(rail.border.color, rail.background).toARGB32(),
      );
      expect(sent['ruleWidth'], family == RaftFamily.brutal ? 2.0 : 1.0);
      expect(sent['dark'], dark);
    }
    final before = runner.named('setStyle').length;
    await tester.pump();
    await tester.pumpWidget(_app(controller, dark: true));
    await tester.pumpAndSettle();
    expect(runner.named('setStyle'), hasLength(before));
  });

  testWidgets('Linux: GTK draws the bar and rule, the app sends colours', (
    tester,
  ) async {
    final runner = _Runner(tester, height: 0);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.linux,
      web: false,
    );
    await tester.pumpWidget(_app(controller, family: RaftFamily.brutal));
    await tester.pump();
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    expect(tester.getRect(find.byKey(const Key('content'))).top, 0);
    expect(runner.named('setStyle'), hasLength(1));
    // Even a runner that wrongly reported a height cannot make the app
    // draw a second strip over the system's bar.
    await runner.push(height: 28);
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
  });

  testWidgets('Windows: only the rule is painted across every theme', (
    tester,
  ) async {
    final runner = _Runner(tester);
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.windows,
      web: false,
    );
    for (final (family, dark) in [
      (RaftFamily.brutal, false),
      (RaftFamily.elegant, false),
      (RaftFamily.elegant, true),
    ]) {
      final tokens = raftTheme(family, dark: dark).extension<RaftTokens>()!;
      final rail = RaftRailRecipe(tokens, viewportHeight: 600);
      final width = family == RaftFamily.brutal ? 2.0 : 1.0;
      double? viewportHeight;
      await tester.pumpWidget(
        _app(
          controller,
          family: family,
          dark: dark,
          child: Builder(
            builder: (context) {
              viewportHeight = MediaQuery.sizeOf(context).height;
              return ColoredBox(
                color: tokens.canvas,
                child: const SizedBox.expand(key: Key('content')),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(RaftDesktopTitleStrip)),
        Rect.fromLTWH(0, 0, 800, width),
      );
      expect(tester.getRect(find.byKey(const Key('content'))).top, width);
      expect(viewportHeight, 600 - width);
      // Inspect the painted pixels, including both ends of the full-width
      // rule and the first content row, rather than only its decoration.
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('titlebar-surface')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          Color pixel(int x, int y) {
            final index = (y * image.width + x) * 4;
            return Color.fromARGB(
              bytes.getUint8(index + 3),
              bytes.getUint8(index),
              bytes.getUint8(index + 1),
              bytes.getUint8(index + 2),
            );
          }

          final rule = Color.alphaBlend(rail.border.color, rail.background);
          for (final x in [0, 400, 799]) {
            for (var y = 0; y < width; y++) {
              expect(pixel(x, y).toARGB32(), rule.toARGB32());
            }
            expect(
              pixel(x, width.toInt()).toARGB32(),
              tokens.canvas.toARGB32(),
            );
          }
        } finally {
          image.dispose();
        }
      });
    }
    await tester.dragFrom(const Offset(400, .5), const Offset(60, 0));
    await tester.tapAt(const Offset(400, .5));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(400, .5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(runner.named('startDragging'), isEmpty);
    expect(runner.named('doubleClick'), isEmpty);
    // Native caption measurements do not add a second title bar.
    await runner.push(height: 28);
    expect(tester.getSize(find.byType(RaftDesktopTitleStrip)).height, 1);
    await runner.push(fullscreen: true);
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    expect(tester.getRect(find.byKey(const Key('content'))).top, 0);
    await runner.push(fullscreen: false);
    expect(tester.getSize(find.byType(RaftDesktopTitleStrip)).height, 1);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform: nothing is drawn or sent', (tester) async {
      final runner = _Runner(tester);
      final controller = DesktopTitleBarController(
        platform: platform,
        web: false,
      );
      await tester.pumpWidget(_app(controller));
      await tester.pump();
      expect(find.byType(RaftDesktopTitleStrip), findsNothing);
      expect(runner.calls, isEmpty);
    });
  }

  testWidgets('macOS bundle without the channel: no strip', (tester) async {
    // An older runner answers nothing: the engine replies "not implemented".
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(DesktopTitleBarController.channelName),
      (call) async => throw MissingPluginException(),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(DesktopTitleBarController.channelName),
        null,
      ),
    );
    final controller = DesktopTitleBarController(
      platform: TargetPlatform.macOS,
      web: false,
    );
    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RaftDesktopTitleStrip), findsNothing);
    expect(controller.state.value.height, 0);
  });
}
