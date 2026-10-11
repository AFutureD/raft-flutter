import 'dart:async';
import 'dart:io' show HttpException, SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/device_preferences.dart';

/// What the root fallback shows (Web RootErrorFallback: `error.message`,
/// `error.stack`, React `componentStack`).
@immutable
class RootErrorReport {
  const RootErrorReport({
    required this.message,
    this.stack,
    this.componentStack,
  });
  final String message;
  final String? stack;
  final String? componentStack;
}

/// Whether an error that escaped every other handler ends the app on the root
/// fallback. The Web boundary catches render errors only; the native app also
/// treats uncaught asynchronous errors as fatal, except the failures a
/// healthy app survives: a rejected request, a lost connection, a plugin that
/// is unavailable or an image that cannot be decoded. Those keep the screen
/// and are only logged.
bool rootErrorIsFatal(Object error, {String? library, String? context}) {
  if (error is RaftApiException ||
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      error is PlatformException ||
      error is MissingPluginException ||
      error is FormatException && library == 'image resource service') {
    return false;
  }
  if (library == 'image resource service' ||
      library == 'gesture library' ||
      library == 'services library') {
    return false;
  }
  final description = context?.toLowerCase() ?? '';
  if (description.contains('gesture') || description.contains('dispatching')) {
    return false;
  }
  return true;
}

/// Collects the first fatal error of this run and tells the boundary.
///
/// Release builds install the handlers ([install]); debug and profile keep
/// Flutter's red/grey error screens and the console report.
class RootErrors extends ChangeNotifier {
  RootErrors._();
  static final RootErrors instance = RootErrors._();

  RootErrorReport? _current;
  RootErrorReport? get current => _current;

  FlutterExceptionHandler? _previousFlutter;
  bool Function(Object, StackTrace)? _previousPlatform;
  ErrorWidgetBuilder? _previousBuilder;
  bool _installed = false;
  bool get installed => _installed;

  /// Routes release-mode errors to the fallback. [release] defaults to
  /// `kReleaseMode`; tests pass true to exercise the release path.
  void install({bool release = kReleaseMode}) {
    if (!release || _installed) return;
    _installed = true;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _previousBuilder = ErrorWidget.builder;
    FlutterError.onError = (details) {
      FlutterError.dumpErrorToConsole(details);
      final library = details.library;
      final context = details.context?.toDescription();
      if (rootErrorIsFatal(
        details.exception,
        library: library,
        context: context,
      )) {
        report(
          details.exception,
          details.stack,
          componentStack: _componentStack(details),
        );
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught error: $error\n$stack');
      if (rootErrorIsFatal(error)) report(error, stack);
      return true;
    };
    // A widget whose build throws: the framework would paint a grey box. The
    // boundary replaces the whole app, as the React boundary does.
    ErrorWidget.builder = (details) {
      report(
        details.exception,
        details.stack,
        componentStack: _componentStack(details),
      );
      return const SizedBox.shrink();
    };
  }

  /// Restores the handlers installed before [install] (tests).
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousFlutter;
    PlatformDispatcher.instance.onError = _previousPlatform;
    if (_previousBuilder != null) ErrorWidget.builder = _previousBuilder!;
    _previousFlutter = null;
    _previousPlatform = null;
    _previousBuilder = null;
  }

  /// Records [error] unless the fallback is already showing one. Notification
  /// waits for the current frame so a build-time report cannot rebuild the
  /// tree it is building.
  void report(Object error, StackTrace? stack, {String? componentStack}) {
    if (_current != null) return;
    _current = RootErrorReport(
      message: error is FlutterError
          ? error.toStringDeep().trim()
          : error.toString(),
      stack: stack == null || stack == StackTrace.empty
          ? null
          : stack.toString().trim(),
      componentStack: componentStack,
    );
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => notifyListeners());
    binding.scheduleFrame();
  }

  /// Reload: forget the error so the boundary remounts the app.
  void clear() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }

  static String? _componentStack(FlutterErrorDetails details) {
    final context = details.context?.toDescription();
    final collected = details.informationCollector?.call() ?? const [];
    final lines = [
      if (context != null && context.isNotEmpty) context,
      for (final node in collected) node.toStringDeep().trim(),
    ].where((line) => line.isNotEmpty).toList();
    return lines.isEmpty ? null : '\n${lines.join('\n')}';
  }
}

/// App.tsx's root `ErrorBoundary` around the whole app: while a fatal error
/// is recorded the fallback page replaces the app; "Reload app" remounts it.
class RootErrorBoundary extends StatefulWidget {
  RootErrorBoundary({super.key, required this.child, RootErrors? errors})
    : errors = errors ?? _shared;
  final Widget child;
  final RootErrors errors;
  static RootErrors get _shared => RootErrors.instance;

  @override
  State<RootErrorBoundary> createState() => _RootErrorBoundaryState();
}

class _RootErrorBoundaryState extends State<RootErrorBoundary> {
  int generation = 0;

  @override
  void initState() {
    super.initState();
    widget.errors.addListener(changed);
  }

  @override
  void didUpdateWidget(covariant RootErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.errors, widget.errors)) {
      oldWidget.errors.removeListener(changed);
      widget.errors.addListener(changed);
    }
  }

  @override
  void dispose() {
    widget.errors.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void reload() {
    generation++;
    widget.errors.clear();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.errors.current;
    if (report == null) {
      return KeyedSubtree(key: ValueKey(generation), child: widget.child);
    }
    return _RootErrorApp(report: report, onReload: reload);
  }
}

/// The fallback owns a minimal app (theme, locale, text direction) because
/// the app that failed is no longer mounted.
class _RootErrorApp extends StatelessWidget {
  const _RootErrorApp({required this.report, required this.onReload});
  final RootErrorReport report;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final preferences = DevicePreferences.current;
    final light = RaftFamily.values.firstWhere(
      (family) => family.name == preferences?.getString('raft.light'),
      orElse: () => RaftFamily.brutal,
    );
    final mode = ThemeMode.values.firstWhere(
      (mode) => mode.name == preferences?.getString('raft.mode'),
      orElse: () => ThemeMode.system,
    );
    final device = WidgetsBinding.instance.platformDispatcher.locale;
    final chinese = device.languageCode == 'zh';
    return MaterialApp(
      title: 'Raft',
      debugShowCheckedModeBanner: false,
      locale: chinese ? const Locale('zh', 'CN') : const Locale('en'),
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: raftTheme(light),
      darkTheme: raftTheme(RaftFamily.elegant, dark: true),
      themeMode: mode,
      home: RaftRootErrorFallback(
        message: report.message,
        stack: report.stack,
        componentStack: report.componentStack,
        onReload: onReload,
      ),
    );
  }
}
