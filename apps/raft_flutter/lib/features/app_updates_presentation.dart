import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_updater/raft_updater.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/user_error.dart';
import '../platform/app_update.dart';
import '../platform/client_release_notes.dart';
import 'app_image_update_text.dart';
import 'resource_cards.dart' show resourceRelativeTime;

// One update presentation for About and the login-independent native menu.
// Both observe the same service and AppImage updater; this owns no session.
class AppUpdatesPresentation extends StatefulWidget {
  const AppUpdatesPresentation({
    super.key,
    required this.builder,
    this.appUpdate,
    this.updater,
  });
  final Widget Function(BuildContext context, RaftAboutUpdate? update) builder;
  final AppUpdateService? appUpdate;
  final AppUpdater? updater;

  @override
  State<AppUpdatesPresentation> createState() => _AppUpdatesPresentationState();
}

class _AppUpdatesPresentationState extends State<AppUpdatesPresentation> {
  UpdateReleaseNotes? _notes;
  ClientReleaseNotes? _notesSource;

  /// The notes of the offered [release] for the Updates card, read once per
  /// offered release; null where this build has no notes source.
  RaftAboutUpdateNotes? _updateNotes(
    AppUpdateService service,
    AppRelease release,
  ) {
    final source = service.releaseNotes;
    if (source == null) return null;
    if (!identical(_notesSource, source)) {
      _notes?.removeListener(_notesChanged);
      _notes?.dispose();
      _notesSource = source;
      _notes = UpdateReleaseNotes(source)..addListener(_notesChanged);
    }
    final notes = _notes!
      ..show(
        release,
        installedTag: service.installedTag,
        installedVersion: service.currentVersion,
      );
    return RaftAboutUpdateNotes(
      status: switch (notes.status) {
        UpdateNotesStatus.loading => RaftAboutUpdateNotesStatus.loading,
        UpdateNotesStatus.ready => RaftAboutUpdateNotesStatus.ready,
        UpdateNotesStatus.empty => RaftAboutUpdateNotesStatus.empty,
        UpdateNotesStatus.failed => RaftAboutUpdateNotesStatus.failed,
      },
      releases: notes.releases,
      onRetry: notes.retry,
    );
  }

  void _notesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _notes?.removeListener(_notesChanged);
    _notes?.dispose();
    super.dispose();
  }

  AppUpdater get _updater => widget.updater ?? AppUpdater.instance;

  /// The Updates card under the Version card; null only where the build has
  /// no update service (Web, public pages).
  ///
  /// macOS and Windows: "Check for updates" runs the same manifest check as
  /// everywhere else and never calls Sparkle / WinSparkle. Their
  /// user-initiated check opens its own dialog ("You're up to date" or the
  /// update flow), which next to this card would answer the same question
  /// twice and, when a release exists, offer the install twice. So the card
  /// answers "is there a newer release?" itself, and "Update now" (shown only
  /// when there is one) hands over to the native updater for the download,
  /// verification, install and relaunch.
  RaftAboutUpdate? update(BuildContext context) {
    final service = widget.appUpdate;
    if (service == null || kIsWeb) return null;
    final platform = Theme.of(context).platform;
    final android = platform == TargetPlatform.android;
    final VoidCallback? check = service.checking
        ? null
        : () => unawaited(service.checkNow());
    switch (service.status) {
      case AppUpdateStatus.unsupported:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.unsupported,
          message: raftText(
            context,
            "Update checks aren't available for this build",
          ),
          detail: raftText(context, switch (service.unsupported) {
            AppUpdateUnsupported.ios =>
              "iOS builds aren't distributed through GitHub releases.",
            AppUpdateUnsupported.linuxPackage =>
              'Only the AppImage build can check for updates.',
            AppUpdateUnsupported.development =>
              'This is a development build without a CI build number.',
            _ => "This platform isn't updated from GitHub releases.",
          }),
        );
      case AppUpdateStatus.checking:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.checking,
          message: raftText(context, 'Checking for updates…'),
        );
      case AppUpdateStatus.idle:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.idle,
          message: raftText(context, 'Not checked for updates yet'),
          onCheck: check,
        );
      case AppUpdateStatus.upToDate:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.upToDate,
          message: raftText(context, "You're on the latest version"),
          detail: _lastChecked(context, service),
          onCheck: check,
        );
      case AppUpdateStatus.failed:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.failed,
          message: raftText(context, "Couldn't check for updates"),
          detail: raftText(
            context,
            userErrorText(
              service.failure,
              fallback: 'Check your connection and try again.',
              where: 'update check',
            ),
          ),
          onCheck: check,
        );
      case AppUpdateStatus.available:
        final release = service.available!;
        final appImage = platform == TargetPlatform.linux
            ? _updater.appImage
            : null;
        // Sparkle / WinSparkle run their own download and install dialogs;
        // this button only starts them. Only a build that can update in place.
        final inPlace =
            (platform == TargetPlatform.macOS ||
                platform == TargetPlatform.windows) &&
            _updater.available;
        Future<void> openReleasePage() => launchUrl(
          android ? release.downloadUrl : release.releasePage,
          mode: LaunchMode.externalApplication,
        );
        if (appImage != null) {
          return _appImageUpdate(
            context,
            service,
            release,
            appImage,
            check,
            openReleasePage,
          );
        }
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.available,
          message: raftFormat(
            context,
            'New version available: {version} ({build})',
            {'version': release.version, 'build': release.buildNumber},
          ),
          detail: _lastChecked(context, service),
          notes: _updateNotes(service, release),
          actionLabel: inPlace
              ? 'Update now'
              : android
              ? 'Download update'
              : 'View release',
          onAction: !inPlace
              ? openReleasePage
              : () async {
                  final outcome = await _updater.checkAndInstall();
                  // openedReleasePage: the plugin already opened the page.
                  if (outcome == AppUpdateOutcome.failed) {
                    await openReleasePage();
                  }
                },
          onCheck: check,
        );
    }
  }

  bool _restartFailed = false;

  /// Linux AppImage: the card itself runs the delta update and shows its
  /// progress, the restart offer and, on failure, the specific reason with the
  /// release page as the fallback.
  RaftAboutUpdate _appImageUpdate(
    BuildContext context,
    AppUpdateService service,
    AppRelease release,
    AppImageUpdater appImage,
    VoidCallback? check,
    Future<void> Function() openReleasePage,
  ) {
    final status = appImage.status.value;
    final label = raftFormat(
      context,
      'New version available: {version} ({build})',
      {'version': release.version, 'build': release.buildNumber},
    );
    switch (status.phase) {
      case AppImageUpdatePhase.idle:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.available,
          message: label,
          detail: _lastChecked(context, service),
          notes: _updateNotes(service, release),
          actionLabel: 'Update now',
          onAction: () => unawaited(() async {
            // A release remembered by an older app version has no checksum or
            // signature yet.
            var target = release;
            if (target.sha256.isEmpty || target.edSignature.isEmpty) {
              await service.checkNow();
              target = service.available ?? target;
            }
            await appImage.install(
              AppImageRelease(
                tag: target.releaseTag,
                artifact: target.artifact,
                sha256: target.sha256,
                bytes: target.bytes,
                edSignature: target.edSignature,
              ),
            );
          }()),
          onCheck: check,
        );
      case AppImageUpdatePhase.running:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.installing,
          message: raftFormat(context, 'Updating to {version} ({build})', {
            'version': release.version,
            'build': release.buildNumber,
          }),
          detail: appImageStageText(context, status),
          progress: status.progress,
          actionLabel: 'Cancel',
          onAction: appImage.cancel,
        );
      case AppImageUpdatePhase.ready:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.restart,
          message: raftFormat(
            context,
            'Raft {version} ({build}) is installed',
            {'version': release.version, 'build': release.buildNumber},
          ),
          detail: raftText(
            context,
            _restartFailed
                ? "Raft couldn't restart itself. Quit it and start it again to finish updating."
                : 'Restart Raft to finish updating.',
          ),
          actionLabel: 'Restart to finish',
          onAction: () async {
            final started = await appImage.restart();
            if (!started && mounted) setState(() => _restartFailed = true);
          },
        );
      case AppImageUpdatePhase.failed:
        return RaftAboutUpdate(
          state: RaftAboutUpdateState.failed,
          message: raftText(context, "Couldn't install the update"),
          detail: appImageFailureText(context, status.failure!),
          actionLabel: 'View release',
          onAction: openReleasePage,
          onCheck: () {
            appImage.reset();
            if (check != null) check();
          },
        );
    }
  }

  String? _lastChecked(BuildContext context, AppUpdateService service) {
    final at = service.lastChecked;
    if (at == null) return null;
    return raftFormat(context, 'Last checked: {time}', {
      'time': resourceRelativeTime(
        at.toIso8601String(),
        now: DateTime.now(),
        chinese: Localizations.localeOf(context).languageCode == 'zh',
      ),
    });
  }

  @override
  Widget build(BuildContext context) {
    final listenable = Listenable.merge([
      ?widget.appUpdate,
      _updater.availability,
      ?_updater.appImage?.status,
    ]);
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) => widget.builder(context, update(context)),
    );
  }
}
