import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_updater/raft_updater.dart';

import '../features/app_updates_presentation.dart';
import '../features/workspace_settings.dart' show WorkspaceAboutSection;
import 'app_update.dart';

class LinuxApplicationMenu extends StatefulWidget {
  const LinuxApplicationMenu({
    super.key,
    required this.navigatorKey,
    required this.appUpdate,
    required this.child,
    this.updater,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final AppUpdateService? appUpdate;
  final AppUpdater? updater;
  final Widget child;

  @override
  State<LinuxApplicationMenu> createState() => _LinuxApplicationMenuState();
}

class _LinuxApplicationMenuState extends State<LinuxApplicationMenu> {
  static const _channel = MethodChannel('app.raft/linux-menu');
  static Object? _handlerOwner;
  late final _linux = !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (!_linux) return;
    _handlerOwner = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'checkForUpdates') throw MissingPluginException();
      return _open();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_linux) return;
    final label = '${raftText(context, 'Check for updates')}…';
    // The navigator is mounted by this frame; no account is needed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_publish(true, label: label));
    });
  }

  Future<void> _publish(bool ready, {String? label}) async {
    if (!identical(_handlerOwner, this)) return;
    try {
      await _channel.invokeMethod<void>('setState', {
        'ready': ready && !_opening,
        'label': ?label,
      });
    } on MissingPluginException {
      // Older Linux runners have no application menu.
    }
  }

  Future<bool> _open() async {
    if (_opening) return false;
    final context = widget.navigatorKey.currentState?.overlay?.context;
    if (context == null || !context.mounted) return false;
    _opening = true;
    await _publish(true);
    try {
      if (!mounted || !context.mounted) return false;
      final service = widget.appUpdate;
      if (service == null || !service.enabled) return await _fallback();
      unawaited(service.checkNow());
      await showDialog<void>(
        context: context,
        builder: (context) => RaftDialogCard(
          key: const Key('linux-update-dialog'),
          title: raftText(context, 'Check for updates'),
          onClose: () => Navigator.of(context).pop(),
          child: AppUpdatesPresentation(
            appUpdate: service,
            updater: widget.updater,
            builder: (context, update) => RaftSettingsAbout(
              version: WorkspaceAboutSection.versionLabel(),
              update: update,
            ),
          ),
        ),
      );
      return true;
    } finally {
      _opening = false;
      if (mounted) await _publish(true);
    }
  }

  Future<bool> _fallback() async {
    do {
      AppUpdateOutcome outcome;
      try {
        outcome = await (widget.updater ?? AppUpdater.instance)
            .checkAndInstall();
      } on Exception {
        outcome = AppUpdateOutcome.failed;
      }
      if (outcome != AppUpdateOutcome.failed) return true;
      final context = widget.navigatorKey.currentState?.overlay?.context;
      if (!mounted || context == null || !context.mounted) return false;
      final retry = await showRaftAlertDialog(
        context: context,
        title: raftText(context, "Couldn't check for updates"),
        description: raftText(context, 'Check your connection and try again.'),
        confirmLabel: raftText(context, 'Try again'),
        cancelLabel: raftText(context, 'Cancel'),
      );
      if (!retry) return false;
    } while (mounted);
    return false;
  }

  @override
  void dispose() {
    if (_linux && identical(_handlerOwner, this)) {
      unawaited(_publish(false));
      _channel.setMethodCallHandler(null);
      _handlerOwner = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
