import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/local_error_diagnostics.dart';

void showLocalErrorToast(BuildContext context, String message) {
  final sample = LocalErrorDiagnostics.shared.forNotice(message);
  showRaftToast(
    context,
    message,
    actionLabel: sample == null ? null : 'Copy diagnostics',
    onAction: sample == null
        ? null
        : () => copyLocalErrorDiagnostics(context, sample: sample),
  );
}

Future<bool> copyLocalErrorDiagnostics(
  BuildContext context, {
  LocalErrorDiagnostics? log,
  LocalErrorSample? sample,
}) async {
  final text = (log ?? LocalErrorDiagnostics.shared).export(sample: sample);
  final toast = RaftToastHost.maybeOf(context);
  final title = toast?.title, action = toast?.onAction;
  bool unchanged() => toast?.title == title && toast?.onAction == action;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted && unchanged()) {
      showRaftToast(
        context,
        'Diagnostics copied',
        tone: RaftToastRecipeTone.success,
      );
    }
    return true;
  } catch (_) {
    if (context.mounted && unchanged()) {
      showRaftToast(
        context,
        'Could not copy diagnostics. Try again.',
        actionLabel: 'Copy diagnostics',
        onAction: () =>
            copyLocalErrorDiagnostics(context, log: log, sample: sample),
      );
    }
    return false;
  }
}

/// Storage always offers this entry, including before any failure is captured.
/// A diagnostic copy remains available after the error toast expires.
class LocalErrorDiagnosticsCard extends StatelessWidget {
  const LocalErrorDiagnosticsCard({super.key, this.log});
  final LocalErrorDiagnostics? log;

  @override
  Widget build(BuildContext context) {
    final held = log ?? LocalErrorDiagnostics.shared;
    return Padding(
      padding: const EdgeInsets.only(top: RaftSpace.x6),
      child: RaftSettingsActionCard(
        title: 'Local error diagnostics',
        description: held.samples.isEmpty
            ? 'No storage errors recorded in this app run. Copy app version and foreground/background state; excludes messages, credentials and server addresses.'
            : 'Copy recent storage errors from this app run for a bug report. Includes app version and foreground/background state; excludes messages, credentials and server addresses.',
        action: RaftSettingsRecipeButton(
          label: 'Copy diagnostics',
          variant: RaftButtonRecipeVariant.outline,
          onPressed: () => copyLocalErrorDiagnostics(context, log: held),
        ),
      ),
    );
  }
}
