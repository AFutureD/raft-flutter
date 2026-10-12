import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../platform/system_bars.dart';

/// Shown at startup when stored credentials exist but the session could not be
/// confirmed (secure storage unavailable, server unreachable, an unexpected
/// reply). The credentials stay on the device and the app keeps retrying; the
/// login form is only offered as an explicit choice, never as the fallback.
class SessionRecoveryView extends StatelessWidget {
  const SessionRecoveryView({
    super.key,
    required this.failure,
    required this.busy,
    required this.onRetry,
    required this.onSignInAgain,
  });
  final SessionRestoreException failure;
  final bool busy;
  final VoidCallback onRetry, onSignInAgain;

  String get headline => switch (failure.kind) {
    SessionRestoreFailureKind.storage =>
      'Your saved sign-in is not available yet',
    SessionRestoreFailureKind.network => 'Cannot reach Raft right now',
    SessionRestoreFailureKind.unexpected =>
      'Raft could not confirm your session',
  };

  String get explanation => switch (failure.kind) {
    SessionRestoreFailureKind.storage =>
      'Your device could not open the secure storage that holds your sign-in. '
          'It is still saved. This usually clears after the device is unlocked.',
    SessionRestoreFailureKind.network =>
      'You are still signed in. Raft will keep trying to reconnect.',
    SessionRestoreFailureKind.unexpected =>
      'You are still signed in. Raft will keep trying to confirm your session.',
  };

  @override
  Widget build(BuildContext context) {
    String tr(String s) => raftText(context, s);
    final t = RaftTokens.of(context);
    return RaftSystemBarSurface(
      statusBarFallback: t.canvas,
      child: RaftAuthResultPage(
        key: const Key('session-recovery'),
        title: tr(headline),
        description: tr(explanation),
        gapBeforeButton: 4,
        buttonKey: const Key('session-recovery-retry'),
        buttonLabel: tr(busy ? 'Trying again…' : 'Try again'),
        onButton: busy ? null : onRetry,
        below: [
          RaftAuthTextLink(
            key: const Key('session-recovery-sign-in'),
            label: tr('Sign in again'),
            centered: true,
            onTap: busy ? null : onSignInAgain,
          ),
        ],
      ),
    );
  }
}
