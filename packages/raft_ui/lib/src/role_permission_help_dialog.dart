// Web `member/RolePermissionHelpDialog.tsx`: a DialogCard titled "Human roles" /
// "Agent roles" holding one `Card p-3` per role (name, summary, details).
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'agent_create_form.dart';
import 'design_primitives.dart';
import 'dialog_card.dart' show RaftRecipeCard;
import 'localization.dart';
import 'panel_layout.dart' show RaftCssText;
import 'theme.dart';

const _humanRoles = [
  (
    'Owner',
    'Full server control.',
    'Billing and ownership. Server settings. Admins and members. Channels, machines, and agents.',
  ),
  (
    'Admin',
    'Operational server admin.',
    'Server profile. Channels and channel members. Agents and machines. Invites, join links, and admin promotion.',
  ),
  (
    'Member',
    'Regular server participant.',
    'Joined channels, DMs, and tasks. Public channel joins. No server-level settings or membership management.',
  ),
];

const _agentRoles = [
  (
    'Admin',
    'Operational server admin.',
    'Server profile. Channels and channel members. No agents, machines, invites, join links, or role promotion yet.',
  ),
  (
    'Member',
    'Regular server participant.',
    'Allowed channels, DMs, and tasks. No server-level settings, channels, or membership management.',
  ),
];

/// Opens the dialog on the Web `Modal` layer (`closeOnBackdrop`: a press on the
/// backdrop closes it).
Future<void> showRaftRolePermissionHelp(
  BuildContext context, {
  required bool agent,
}) {
  final t = RaftTokens.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: raftAgentModalBarrier(t),
    transitionDuration: const Duration(milliseconds: 150),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
    // `Modal`: `backdrop-blur-[2px]` over the page (the Dialog layer has none).
    pageBuilder: (context, _, _) => BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
      child: RaftRolePermissionHelpDialog(
        agent: agent,
        onClose: () => Navigator.of(context).pop(),
      ),
    ),
  );
}

class RaftRolePermissionHelpDialog extends StatelessWidget {
  const RaftRolePermissionHelpDialog({
    super.key,
    required this.agent,
    required this.onClose,
  });
  final bool agent;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final strong = t.brutal ? Colors.black : t.strong;
    final summary = t.brutal ? Colors.black.withValues(alpha: .6) : t.muted;
    final details = t.brutal ? Colors.black.withValues(alpha: .75) : t.muted;
    return RaftAgentDialogCard(
      surfaceKey: const ValueKey('role-help-dialog'),
      title: agent ? 'Agent roles' : 'Human roles',
      onClose: onClose,
      children: [
        // `space-y-3`
        for (final (i, (role, sum, text)) in (agent ? _agentRoles : _humanRoles).indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          RaftRecipeCard(
            padding: const EdgeInsets.all(12), // p-3
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4), // mb-1
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8, // gap-x-2
                    runSpacing: 4, // gap-y-1
                    children: [
                      RaftCssText(
                        raftText(context, role),
                        style: RaftTypography.body(
                          t,
                          size: 14,
                          line: 20,
                          weight: FontWeight.w700,
                          color: strong,
                        ),
                      ),
                      RaftCssText(
                        raftText(context, sum),
                        style: RaftTypography.body(
                          t,
                          size: 12,
                          line: 16,
                          weight: FontWeight.w700,
                          color: summary,
                        ),
                      ),
                    ],
                  ),
                ),
                RaftCssText(
                  raftText(context, text),
                  style: RaftTypography.body(
                    t,
                    size: 14,
                    line: 14 * 1.625,
                    color: details,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
