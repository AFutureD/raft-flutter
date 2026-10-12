import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/root_error_boundary.dart';
import 'package:raft_ui/raft_ui.dart';

class _Bomb extends StatelessWidget {
  const _Bomb();
  @override
  Widget build(BuildContext context) => throw StateError('channel header broke');
}

int _builds = 0;

class _Counter extends StatelessWidget {
  const _Counter();
  @override
  Widget build(BuildContext context) {
    _builds++;
    return const Directionality(
      textDirection: TextDirection.ltr,
      child: Text('app'),
    );
  }
}

void main() {
  test('which errors end the app on the fallback', () {
    expect(rootErrorIsFatal(StateError('x')), isTrue);
    expect(rootErrorIsFatal(StateError('x'), library: 'widgets library'), isTrue);
    expect(rootErrorIsFatal(const RaftApiException('offline')), isFalse);
    expect(rootErrorIsFatal(const SocketException('lost')), isFalse);
    expect(rootErrorIsFatal(TimeoutException('slow')), isFalse);
    expect(
      rootErrorIsFatal(StateError('x'), library: 'image resource service'),
      isFalse,
    );
    expect(
      rootErrorIsFatal(
        StateError('x'),
        library: 'widgets library',
        context: 'while handling a gesture',
      ),
      isFalse,
    );
  });

  group('release path', () {
    late RootErrors errors;
    final originalBuilder = ErrorWidget.builder;
    final originalOnError = FlutterError.onError;

    setUp(() {
      errors = RootErrors.instance..clear();
      errors.install(release: true);
      _builds = 0;
    });
    tearDown(() {
      errors.uninstall();
      errors.clear();
      ErrorWidget.builder = originalBuilder;
      FlutterError.onError = originalOnError;
    });

    testWidgets('a build error replaces the app with the fallback and reload remounts it', (
      tester,
    ) async {
      var broken = true;
      await tester.pumpWidget(
        RootErrorBoundary(
          errors: errors,
          child: Builder(
            builder: (_) => broken ? const _Bomb() : const _Counter(),
          ),
        ),
      );
      // The framework reports the build error; the boundary swaps in the page.
      tester.takeException();
      await tester.pump();
      await tester.pump();
      expect(find.text('Something went wrong'), findsOneWidget);
      // The raw exception is not printed on the page: it sits in the closed
      // "Stack trace" disclosure.
      expect(find.textContaining('channel header broke'), findsNothing);
      expect(find.byKey(const ValueKey('root-error-message')), findsNothing);
      expect(find.text('Reload app'), findsOneWidget);
      expect(find.byType(_Bomb), findsNothing);

      broken = false;
      await tester.tap(find.text('Reload app'));
      await tester.pump();
      expect(find.text('Something went wrong'), findsNothing);
      expect(find.text('app'), findsOneWidget);
      expect(_builds, greaterThan(0));
    });

    testWidgets('an uncaught async error shows the fallback, a network error does not', (
      tester,
    ) async {
      await tester.pumpWidget(
        RootErrorBoundary(errors: errors, child: const _Counter()),
      );
      final handler = tester.binding.platformDispatcher.onError!;
      handler(const RaftApiException('offline'), StackTrace.current);
      await tester.pump();
      expect(find.text('app'), findsOneWidget);
      expect(errors.current, isNull);

      handler(StateError('lost state'), StackTrace.current);
      await tester.pump();
      await tester.pump();
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(errors.current?.message, contains('lost state'));
    });

    testWidgets('the first error stays on screen', (tester) async {
      await tester.pumpWidget(
        RootErrorBoundary(errors: errors, child: const _Counter()),
      );
      final handler = tester.binding.platformDispatcher.onError!;
      handler(StateError('first'), StackTrace.current);
      handler(StateError('second'), StackTrace.current);
      await tester.pump();
      await tester.pump();
      expect(errors.current?.message, contains('first'));
    });

    testWidgets('the fallback shows Chinese for a Chinese device', (tester) async {
      tester.platformDispatcher.localeTestValue = const Locale('zh', 'CN');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      errors.report(StateError('boom'), null);
      await tester.pumpWidget(
        RootErrorBoundary(errors: errors, child: const _Counter()),
      );
      await tester.pump();
      expect(find.text('出了点问题'), findsOneWidget);
      expect(find.text('重新加载应用'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      await tester.tap(find.text('错误堆栈'));
      await tester.pump();
      expect(find.textContaining('boom'), findsOneWidget);
    });
  });

  test('debug and profile builds keep the framework handlers', () {
    final before = FlutterError.onError, builder = ErrorWidget.builder;
    final errors = RootErrors.instance;
    errors.install(release: false);
    expect(errors.installed, isFalse);
    expect(identical(FlutterError.onError, before), isTrue);
    expect(identical(ErrorWidget.builder, builder), isTrue);
  });

  testWidgets('the fallback page lists the error, disclosures and reload', (
    tester,
  ) async {
    var reloaded = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: RaftRootErrorFallback(
            message: 'Cannot read properties',
            stack: 'TypeError: x\n  at a',
            componentStack: '\n  at ChannelHeader',
            onReload: () => reloaded++,
          ),
        ),
      ),
    );
    expect(find.text('Cannot read properties'), findsOneWidget);
    expect(find.text('Stack trace'), findsOneWidget);
    // Component stack opens by default, stack trace starts closed.
    expect(find.textContaining('at ChannelHeader'), findsOneWidget);
    expect(find.textContaining('TypeError: x'), findsNothing);
    await tester.tap(find.text('Stack trace'));
    await tester.pump();
    expect(find.textContaining('TypeError: x'), findsOneWidget);
    await tester.tap(find.text('Reload app'));
    expect(reloaded, 1);
  });
}
