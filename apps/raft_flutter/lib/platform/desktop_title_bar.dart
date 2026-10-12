import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_ui/raft_ui.dart';

/// Who paints the desktop title bar.
enum DesktopTitleBarMode {
  /// Not a desktop window with a title bar the app can colour.
  none,

  /// macOS: the content view runs under a transparent title bar, so the app
  /// draws the strip itself in the space the native bar leaves and reports.
  strip,

  /// Linux and Windows: the system draws the bar (a GTK header bar, a DWM
  /// caption); the app only tells it which colours to use.
  native,
}

/// What the native window reports about its title bar.
@immutable
class DesktopTitleBarState {
  const DesktopTitleBarState({this.height = 0, this.fullscreen = false});

  /// The title bar's height in logical pixels; zero when the window has none.
  final double height;

  /// Whether the window is fullscreen. macOS hides its title bar then.
  final bool fullscreen;

  @override
  bool operator ==(Object other) =>
      other is DesktopTitleBarState &&
      other.height == height &&
      other.fullscreen == fullscreen;

  @override
  int get hashCode => Object.hash(height, fullscreen);
}

/// The colours the title bar wears, from the rail recipe of the current theme.
@immutable
class DesktopTitleBarStyle {
  const DesktopTitleBarStyle({
    required this.background,
    required this.foreground,
    required this.rule,
    required this.ruleWidth,
  });

  factory DesktopTitleBarStyle.of(RaftTokens tokens) {
    final recipe = RaftTitleBarRecipe(tokens);
    return DesktopTitleBarStyle(
      background: recipe.background,
      foreground: recipe.foreground,
      rule: recipe.rule,
      ruleWidth: recipe.ruleWidth,
    );
  }

  final Color background, foreground, rule;
  final double ruleWidth;

  Map<String, Object> toArguments() => {
    'background': background.toARGB32(),
    'foreground': foreground.toARGB32(),
    // The system paints the rule opaque: resolve a translucent divider (the
    // dark Elegant one) over the strip, the way the Flutter strip shows it.
    'rule': Color.alphaBlend(rule, background).toARGB32(),
    'ruleWidth': ruleWidth,
    'dark': background.computeLuminance() < .5,
  };

  @override
  bool operator ==(Object other) =>
      other is DesktopTitleBarStyle &&
      other.background == background &&
      other.foreground == foreground &&
      other.rule == rule &&
      other.ruleWidth == ruleWidth;

  @override
  int get hashCode => Object.hash(background, foreground, rule, ruleWidth);
}

/// The Dart side of the runner's `app.raft/titlebar` channel.
///
/// Dart to native: `status` (reads the state), `setStyle` (colours), and on
/// macOS `startDragging` / `doubleClick`. Native to Dart: `state`, whenever the
/// title bar's height or the window's fullscreen state changes.
class DesktopTitleBarController {
  DesktopTitleBarController({
    MethodChannel? channel,
    TargetPlatform? platform,
    bool? web,
  }) : _channel = channel ?? const MethodChannel(channelName),
       mode = _modeFor(platform ?? defaultTargetPlatform, web ?? kIsWeb);

  static const channelName = 'app.raft/titlebar';

  /// macOS's standard title bar, until the window says otherwise. The first
  /// frame is drawn before the runner's answer arrives.
  static const macosDefaultHeight = 28.0;

  static final DesktopTitleBarController platform = DesktopTitleBarController();

  static DesktopTitleBarMode _modeFor(TargetPlatform platform, bool web) {
    if (web) return DesktopTitleBarMode.none;
    return switch (platform) {
      TargetPlatform.macOS => DesktopTitleBarMode.strip,
      TargetPlatform.linux ||
      TargetPlatform.windows => DesktopTitleBarMode.native,
      _ => DesktopTitleBarMode.none,
    };
  }

  final MethodChannel _channel;
  final DesktopTitleBarMode mode;
  late final ValueNotifier<DesktopTitleBarState> state = ValueNotifier(
    DesktopTitleBarState(
      height: mode == DesktopTitleBarMode.strip ? macosDefaultHeight : 0,
    ),
  );
  bool _started = false;
  DesktopTitleBarStyle? _sent;

  /// Listen for the runner's reports and read the first one. Safe to call
  /// again; an older bundle without the channel keeps the defaults.
  Future<void> start() async {
    if (_started || mode == DesktopTitleBarMode.none) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'state') _receive(call.arguments);
    });
    try {
      _receive(await _channel.invokeMethod<Object?>('status'));
    } on MissingPluginException {
      if (mode == DesktopTitleBarMode.strip) {
        state.value = const DesktopTitleBarState();
      }
    }
  }

  void _receive(Object? value) {
    if (value is! Map) return;
    final height = value['height'];
    final fullscreen = value['fullscreen'];
    state.value = DesktopTitleBarState(
      height: mode == DesktopTitleBarMode.strip && height is num
          ? height.toDouble()
          : 0,
      fullscreen: fullscreen == true,
    );
  }

  /// Tell the runner the colours; repeated identical styles are dropped.
  Future<void> setStyle(DesktopTitleBarStyle style) async {
    if (mode == DesktopTitleBarMode.none || style == _sent) return;
    _sent = style;
    try {
      await _channel.invokeMethod<void>('setStyle', style.toArguments());
    } on MissingPluginException {
      // An older bundle: the window keeps its own title bar.
    }
  }

  Future<void> startDragging() => _fire('startDragging');

  Future<void> doubleClick() => _fire('doubleClick');

  Future<void> _fire(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // An older bundle: the traffic lights still move the window.
    }
  }
}

/// Gives the desktop window its title strip above [child] (macOS), or colours
/// the system's own title bar to match the rail (Linux, Windows). Sits below
/// the theme so it follows every theme change.
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key, this.controller, required this.child});

  final DesktopTitleBarController? controller;
  final Widget child;

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> {
  DesktopTitleBarController get _controller =>
      widget.controller ?? DesktopTitleBarController.platform;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs again whenever the theme changes, so a live switch is sent at once.
    unawaited(
      _controller.setStyle(DesktopTitleBarStyle.of(RaftTokens.of(context))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller.mode == DesktopTitleBarMode.none) return widget.child;
    if (controller.mode == DesktopTitleBarMode.native) return widget.child;
    return ValueListenableBuilder<DesktopTitleBarState>(
      valueListenable: controller.state,
      child: widget.child,
      builder: (context, state, child) => RaftDesktopTitleBar(
        height: state.height,
        fullscreen: state.fullscreen,
        onDragStart: () => unawaited(controller.startDragging()),
        onDoubleTap: () => unawaited(controller.doubleClick()),
        child: child!,
      ),
    );
  }
}
