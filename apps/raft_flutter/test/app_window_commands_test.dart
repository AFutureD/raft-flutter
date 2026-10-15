import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/raft_location.dart';
import 'package:raft_flutter/platform/desktop_title_bar.dart';
import 'package:raft_ui/raft_ui.dart';

import 'app_global_server_selector_test.dart' show RootFixture;

Future<void> _mount(WidgetTester t, RootFixture f) async {
  await f.mount(t, 'elegant', 1200);
  await t.tap(find.byKey(const ValueKey('global-server-a')));
  await f.flush(t);
  expect(find.byType(TextField), findsWidgets);
}

Future<void> _key(WidgetTester t, LogicalKeyboardKey modifier) async {
  await t.sendKeyDownEvent(modifier);
  await t.sendKeyEvent(LogicalKeyboardKey.keyW);
  await t.sendKeyUpEvent(modifier);
  await t.pump();
}

void _nativeCommand(WidgetTester t, String method) {
  unawaited(
    t.binding.defaultBinaryMessenger.handlePlatformMessage(
      'app.raft/window',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    ),
  );
}

Future<void> _preview(WidgetTester t, RootFixture f) async {
  final context = f.router(t).navigatorKey.currentContext!;
  unawaited(
    showDialog<void>(
      context: context,
      builder: (context) => RaftAttachmentPreviewShell(
        filename: 'window-shortcut.md',
        onClose: () => Navigator.of(context).pop(),
        child: const Text('Preview remains inside the existing window'),
      ),
    ),
  );
  await f.flush(t);
  expect(find.byType(RaftAttachmentPreviewShell), findsOneWidget);
}

void main() {
  tearDownAll(() => DesktopTitleBarController.platform.state.dispose());
  for (final (platform, modifier, channel) in const [
    (TargetPlatform.macOS, LogicalKeyboardKey.metaLeft, 'app.raft/window'),
    (
      TargetPlatform.windows,
      LogicalKeyboardKey.controlLeft,
      'app.raft/windows-tray',
    ),
  ]) {
    for (final editorFocused in [false, true]) {
      testWidgets('$platform closes the window with W; editor=$editorFocused', (
        t,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        final calls = <String>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
        final f = RootFixture();
        try {
          await _mount(t, f);
          if (editorFocused) {
            await t.enterText(find.byType(TextField).last, 'Keep this draft');
          } else {
            FocusManager.instance.primaryFocus?.unfocus();
            await t.pump();
          }
          await _key(t, modifier);
          await f.flush(t);
          expect(
            calls.where((method) => method == 'closeWindow'),
            hasLength(1),
          );
        } finally {
          await f.close(t);
          debugDefaultTargetPlatformOverride = null;
          t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel(channel),
            null,
          );
        }
      });
    }
  }

  for (final (platform, modifier, wrongModifier, channel) in const [
    (
      TargetPlatform.macOS,
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
      'app.raft/window',
    ),
    (
      TargetPlatform.windows,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
      'app.raft/windows-tray',
    ),
  ]) {
    testWidgets('$platform keeps previews ahead of the window fallback', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final calls = <String>[];
      final bridge = MethodChannel(channel);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final f = RootFixture();
      try {
        await _mount(t, f);
        await _key(t, wrongModifier);
        expect(calls.where((method) => method == 'closeWindow'), isEmpty);
        await _preview(t, f);
        await _key(t, modifier);
        await f.flush(t);
        expect(find.byType(RaftAttachmentPreviewShell), findsNothing);
        expect(calls.where((method) => method == 'closeWindow'), isEmpty);
        await _key(t, modifier);
        await f.flush(t);
        expect(calls.where((method) => method == 'closeWindow'), hasLength(1));
      } finally {
        await f.close(t);
        debugDefaultTargetPlatformOverride = null;
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, null);
      }
    });
  }

  testWidgets('a protected dialog blocks native Close and Preferences', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final calls = <String>[];
    const channel = MethodChannel('app.raft/window');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return null;
    });
    final f = RootFixture();
    try {
      await _mount(t, f);
      unawaited(
        showDialog<void>(
          context: f.router(t).navigatorKey.currentContext!,
          builder: (_) => const PopScope(
            canPop: false,
            child: Dialog(child: Text('Protected operation')),
          ),
        ),
      );
      await f.flush(t);
      _nativeCommand(t, 'closeRequested');
      await f.flush(t);
      _nativeCommand(t, 'openPreferences');
      await f.flush(t);
      expect(find.text('Protected operation'), findsOneWidget);
      expect(calls.where((method) => method == 'closeWindow'), isEmpty);
      expect(f.workspace(t).location.route, RaftRoute.channel);
      f.router(t).navigatorKey.currentState!.pop();
      await f.flush(t);
    } finally {
      await f.close(t);
      debugDefaultTargetPlatformOverride = null;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets(
    'native Close first dismisses the preview, then closes the window',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final calls = <String>[];
      const channel = MethodChannel('app.raft/window');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final f = RootFixture();
      try {
        await _mount(t, f);
        await _preview(t, f);
        _nativeCommand(t, 'closeRequested');
        await f.flush(t);
        expect(find.byType(RaftAttachmentPreviewShell), findsNothing);
        expect(calls.where((method) => method == 'closeWindow'), isEmpty);
        _nativeCommand(t, 'closeRequested');
        await f.flush(t);
        expect(calls.where((method) => method == 'closeWindow'), hasLength(1));
      } finally {
        f
            .router(t)
            .navigatorKey
            .currentState
            ?.popUntil((route) => route.isFirst);
        await f.flush(t);
        // Drain requests the old app buffered before a listener was installed.
        t.binding.defaultBinaryMessenger.setMessageHandler(
          'app.raft/window',
          (_) async => null,
        );
        await t.pump();
        await f.close(t);
        t.binding.defaultBinaryMessenger.setMessageHandler(
          'app.raft/window',
          null,
        );
        debugDefaultTargetPlatformOverride = null;
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
    },
  );

  testWidgets(
    'native Preferences dismisses a preview and opens Settings Account',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final f = RootFixture();
      try {
        await _mount(t, f);
        await _preview(t, f);
        _nativeCommand(t, 'openPreferences');
        await f.flush(t);
        expect(find.byType(RaftAttachmentPreviewShell), findsNothing);
        expect(f.workspace(t).location.route, RaftRoute.settings);
        expect(
          f.workspace(t).location.settingsPath,
          anyOf(isEmpty, ['account']),
        );
      } finally {
        f
            .router(t)
            .navigatorKey
            .currentState
            ?.popUntil((route) => route.isFirst);
        await f.flush(t);
        t.binding.defaultBinaryMessenger.setMessageHandler(
          'app.raft/window',
          (_) async => null,
        );
        await t.pump();
        await f.close(t);
        t.binding.defaultBinaryMessenger.setMessageHandler(
          'app.raft/window',
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
