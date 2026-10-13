/// Imperative notice holders allowed by notice_state_guard_test.dart: file ->
/// trimmed source line -> the conditions that clear it. Prefer a `CauseNotice`
/// (lib/data/cause_notice.dart) for new code. A line shared by several
/// declarations in one file lists the condition of each, joined by ` | `.
const noticeStateAllow = <String, Map<String, String>>{
  'apps/raft_flutter/lib/data/workspace_controller.dart': {
    'String? id, error;':
        'Per-upload failure on its draft chip; composer upload state owned by the lead (cleared on retry, removal or send).',
    'setError(':
        'Cache-purge device failures and background refresh failures raise a one-shot toast; stale-scope and rate-limited failures are suppressed (_quietFailure) and the error is cleared on server switch or revoke.',
    'String? _threadResolutionError;':
        'Cleared when a thread opens or closes and hidden whenever threadIdentity is stale.',
    'String? error;':
        'One-shot toast consumed by WorkspaceView; cleared on channel open, jump, send start, server switch and server revoke.',
    'source.setError(value);': 'Delegates to the session source.',
    'setError(userErrorText(e, where: \'refresh channels\'));':
        'Raised only for the current ledger generation and not for rate-limited or stale-scope failures; cleared on server switch or revoke.',
    'setError(userErrorText(e, where: \'refresh servers\'));':
        'Raised only for the latest membership request on the current client generation and not for rate-limited or stale-scope failures.',
    'setError(userErrorText(e, where: \'join channel\'));':
        'User-initiated join; stale-scope failures are not reported; cleared on server switch or revoke.',
    'setError(userErrorText(e, where: \'join thread parent channel\'));':
        'User-initiated join; stale-scope failures are not reported; cleared on server switch or revoke.',
  },
  'apps/raft_flutter/lib/features/account_onboarding.dart': {
    'String? notice, handleError, displayNameError;':
        'handleError/displayNameError clear when the field is edited and are recomputed on submit; notice is never raised (always null).',
  },
  'apps/raft_flutter/lib/features/account_password_editor.dart': {
    'String? error;':
        'Cleared when the next save starts, a validation attempt runs, the form is collapsed or the account changes.',
  },
  'apps/raft_flutter/lib/features/account_settings.dart': {
    'String? profileError;':
        'Clears when the next save starts and on account change (clearData/hydrateProfile).',
    'String? mediaError;':
        'Clears when the next avatar action starts and on account change (clearData).',
  },
  'apps/raft_flutter/lib/features/add_members_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/administration_view.dart': {
    'String? selectedKey, savingKey, error;':
        'error clears when the next role change starts (Web setError(\'\') in handlePromote/handleDemote); the section is remounted on server/account change.',
    'String? error;':
        'Each section\'s error clears when its next save/action starts, on a successful load, and when the real server state it describes changes (_resync); sections are remounted on server/account change.',
    'String? createError, copiedId;':
        'createError clears when the next create starts; copiedId expires after 1.5 s; the section is remounted on server/account change.',
  },
  'apps/raft_flutter/lib/features/agent_avatar_dialog.dart': {
    'String? error;':
        'Cleared when another avatar is chosen or uploaded, or the next save starts; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/agent_detail_view.dart': {
    'String? externalStatusError;':
        'Cleared when a status read succeeds and on an agent change (didUpdateWidget); stale reads are fenced by externalStatusFor.',
    'String? channelsError, dmsError;':
        'Rewritten (null on success) by every reload of the chat tab snapshot, which is keyed by agent and server.',
    'String? loadError;':
        'Cleared when reload() starts, set only for a current ticket and only when nothing is on screen; the tab is keyed by agent.',
    'String? openError;':
        'Cleared when the next file opens; set only for the current open ticket and file.',
  },
  'apps/raft_flutter/lib/features/agent_runtime_editor.dart': {
    'String? saveError;':
        'Cleared at the start of every Save (legacy and protocol-v2) and gone with the dialog.',
  },
  'apps/raft_flutter/lib/features/agent_scopes_view.dart': {
    'String? error;':
        'Clears on a successful read, on Retry and when a save starts; the page is a route per agent and is disposed on navigation.',
  },
  'apps/raft_flutter/lib/features/attachment_comments_view.dart': {
    'String? error;':
        'Load error: cleared by a successful load, a rebind to another attachment/controller and a scope revocation.',
  },
  'apps/raft_flutter/lib/features/attachment_html_preview.dart': {
    'String? html, error;':
        'Preview error: cleared by load()/interactive() and scope loss; link errors are NOT cleared by a later successful link (see inv-a.md, other agent owns the file).',
  },
  'apps/raft_flutter/lib/features/attachment_preview_dialog.dart': {
    'String? error;':
        'Preview failure panel: reset by retry() and rebinding; terminal for playback/PDF errors (the panel replaces the player) and dies with the dialog or authority loss.',
  },
  'apps/raft_flutter/lib/features/attachment_view.dart': {
    'String? error;':
        'Image load error: cleared when an image load starts, on a ready image adoption and on rebind.',
  },
  'apps/raft_flutter/lib/features/auth_view.dart': {
    'String? emailError, passwordError, confirmError, tokenError;':
        'Each clears when its field is edited, on submit revalidation and on mode switch.',
    'String? error, notice;':
        'error clears on submit, social sign-in start, mode switch and server edit; notice is never raised (always null).',
  },
  'apps/raft_flutter/lib/features/billing_view.dart': {
    'String billingError = \'\', billingNotice = \'\';':
        'Both clear when the next billing action starts (Web setBillingError/Notice(\'\') at each handler) and on account/server change (clearData).',
  },
  'apps/raft_flutter/lib/features/channel_members.dart': {
    'String? error;':
        'Cleared when the next add or role change starts, the add selection changes or the add view is left.',
  },
  'apps/raft_flutter/lib/features/channel_settings.dart': {
    'String? error;':
        'Cleared when an action starts, a load succeeds, the draft is reset or the name or description is edited; the drawer state is dropped on close.',
  },
  'apps/raft_flutter/lib/features/chat_view.dart': {
    'String? selectionError;':
        'Selection toolbar error: cleared when the selection ends (selectionChanged), on rebind and when a preview capture starts.',
    'w.setComposerError(':
        'Attach-selection failure: the composer notice store ends it with the composer visit (channel/thread change), the next accepted send, or the next selection\'s decision.',
  },
  'apps/raft_flutter/lib/features/composer_attachment_input.dart': {
    'w.setComposerError(':
        'Drop notices (unreadable drop, skipped folders): composer notice store; ends with the composer visit, the next accepted send, or the next selection\'s decision (Web handleDrop/setError).',
  },
  'apps/raft_flutter/lib/features/composer_attachments_view.dart': {
    'w.setComposerError(':
        'Blocked-send notice raised with a whileTrue predicate over the live uploads: gone when they finish, are removed or change state; also ends on send and channel change.',
  },
  'apps/raft_flutter/lib/features/connected_app_editor.dart': {
    'String? savingId, error, webhookBusy, webhookSecret;':
        'error clears when the next save or guarded action starts or a confirm dialog retries; webhookSecret is a one-time value cleared on disable and with the editor.',
  },
  'apps/raft_flutter/lib/features/create_agent_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts or the name is edited; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/create_channel_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/create_joint_channel_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts or the invite list changes; the dialog state is dropped when it closes.',
    'bool billingError = false, submitting = false;':
        'billingError is cleared with the error text it decorates (submit start or an invite change).',
  },
  'apps/raft_flutter/lib/features/create_task_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/external_agent_setup.dart': {
    'bool listError = false, revokeError = false;':
        'listError clears when a list load succeeds or Refresh runs; revokeError clears when a revoke prompt opens, Refresh runs, the next revoke starts or the account changes.',
    'bool pending = false, error = false, copied = false;':
        'error clears when the next generate starts or the account changes; copied clears with the token (revoke or account change).',
  },
  'apps/raft_flutter/lib/features/fleet_views.dart': {
    'String? actionError;':
        'Cleared on scope change and controller change; only set by a defensive catch around showManagedAgentForm, which does not throw.',
    'String? error;':
        'Cleared when an action starts, a detail read succeeds, the user dismisses it, or the profile closes for an authority change.',
  },
  'apps/raft_flutter/lib/features/incoming_share_picker.dart': {
    'String? handoffError;':
        'Cleared when Continue starts and when a destination row is tapped (the only ways into the review step).',
    'String? error;':
        'Load error with Retry: cleared when a load starts or when a server read succeeds with no server; retry calls load.',
  },
  'apps/raft_flutter/lib/features/integrations_views.dart': {
    'String? modalError;':
        'Cleared when the install retry starts; the local variable dies with the app detail modal.',
    'String? error;':
        'Cleared when the next load of the installed-app notification settings succeeds; the state is dropped with the page.',
  },
  'apps/raft_flutter/lib/features/invite_accept_view.dart': {
    'String acceptedName = \'\', acceptedId = \'\', error = \'\';':
        'error clears when a join starts or the invite token changes; a result for a previous token is ignored.',
  },
  'apps/raft_flutter/lib/features/labs_view.dart': {
    'String? mutationError;':
        'Clears when the next toggle starts and on account/server change (clearData); the page is remounted on server change.',
  },
  'apps/raft_flutter/lib/features/locale_settings_page.dart': {
    'String? languageError, dateTimeError;':
        'Each clears when its form is edited, when its save starts, and on account change (clearData).',
  },
  'apps/raft_flutter/lib/features/managed_agent_launcher.dart': {
    'String? failure;':
        'Cleared when Retry starts a new load or when the computers list arrives (it only shows while no list is known).',
  },
  'apps/raft_flutter/lib/features/management_support.dart': {
    'String? error;':
        'Cleared when a load succeeds, an action starts, the account or workspace authority changes; a load failure keeps the accepted data and stays until the next reload.',
  },
  'apps/raft_flutter/lib/features/member_graph_view.dart': {
    'String? error;':
        'Clears when a load starts (Retry) and on server change; stale tickets are ignored.',
  },
  'apps/raft_flutter/lib/features/member_profile_view.dart': {
    'String? roleError;':
        'Clears when the role editor is opened or cancelled, when a save starts, and when the viewed member or server/account changes (clearData); a late failure for another member is ignored.',
  },
  'apps/raft_flutter/lib/features/message_image_export.dart': {
    'String? error;':
        'Export dialog error: cleared when the next save/share starts; the dialog closes on authority loss.',
  },
  'apps/raft_flutter/lib/features/message_presentation.dart': {
    'if (current()) w.setError(\'Could not export diagram.\');':
        'Workspace-level w.error is shown once as a toast by workspace_view.syncWorkspaceError and cleared there (self-dismissing).',
  },
  'apps/raft_flutter/lib/features/message_selection.dart': {
    'String? _scope, error;':
        'Selection-limit notice: cleared on a successful select, a deselect, select all, exit and any scope/authority change.',
  },
  'apps/raft_flutter/lib/features/network_settings.dart': {
    'String? formError;':
        'Clears when any proxy field is edited (touch), when a save/test starts, and on dispose.',
  },
  'apps/raft_flutter/lib/features/notification_settings_view.dart': {
    'String? error, message;':
        'Both clear on the next save/native action, on a mute edit, on a pushed prefs update, on retry success and on server/account/service change (clear()).',
  },
  'apps/raft_flutter/lib/features/pending_mention_actions.dart': {
    'w.setComposerError(null, thread: widget.thread);':
        'Clears the composer banner at the start of a mention action (mark) and when a row is dismissed (Web removePendingMentionAction).',
    'w.setComposerError(':
        'Raises the server\'s text when the action request throws; the composer notice store ends it with the composer visit and the next mark/dismiss clears it.',
  },
  'apps/raft_flutter/lib/features/provider_edit_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts; the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/public_server_view.dart': {
    'String error = \'\';':
        'Page load error: cleared at the start of every server/messages/older load and on a server reload.',
    'bool selectionNotice = false;':
        'Anonymous rail prompt (Web keeps it sticky): shown only while the visitor is signed out.',
    'String threadError = \'\';':
        'Thread panel error: cleared when a thread is opened (it replaces the thread body, as in Web).',
    'String joinError = \'\';':
        'Join failure banner: cleared when a join starts and when the server (slug/client) reloads; kept after cancelling the dialog as in Web.',
  },
  'apps/raft_flutter/lib/features/public_visibility_view.dart': {
    'String? error;':
        'Clears when the read starts or a change starts (Web setError(\'\') at submit); the page is remounted on server/account change.',
  },
  'apps/raft_flutter/lib/features/resource_view.dart': {
    'String? error;':
        'Cleared when a load starts or succeeds, on authority change and on initialQuery change; set only for the accepted scope/request.',
  },
  'apps/raft_flutter/lib/features/runtime_form_dialog.dart': {
    'Map<String, String> serverErrors = {};':
        'Cleared when any field value changes; the controller is disposed with the dialog.',
    'String? error;':
        'Controller load error: cleared when load restarts (Try again) or completes; dialog submit error: cleared when the next submit starts; both are disposed with the dialog.',
    'String? onboardingLoadError;':
        'Cleared when the machines load succeeds (Try again re-runs it); the dialog state is dropped when it closes.',
  },
  'apps/raft_flutter/lib/features/runtime_usage_chip.dart': {
    'bool loading = false, loadError = false;':
        'loadError is reset when each read starts and set only for the current subject ticket.',
  },
  'apps/raft_flutter/lib/features/server_setup_gate.dart': {
    'String? createdAgentId, notice;':
        'createdAgentId clears on setup reset and server/account switch (clearData); notice is written by reset() but never rendered and clears on server/account switch (clearData).',
  },
  'apps/raft_flutter/lib/features/server_views.dart': {
    'String? savedName, error, avatarError, _avatarServerId;':
        'error clears when the next save starts; the page is remounted on server/account change (WorkspaceSettings key). '
        'avatarError is scoped to _avatarServerId and clears on retry, on a successful upload, on switching server and '
        'when the user loses edit permission (server_avatar_test).',
    'String? error;':
        'Members load/profile error clears on the next successful load or Retry; the page is disposed on navigation.',
  },
  'apps/raft_flutter/lib/features/workspace_view.dart': {
    'w.setError(null);': 'Consumes the pending workspace error into a toast.',
    'w.setError(userErrorText(e, where: \'open documentation\'));':
        'Workspace error is a one-shot toast, consumed by syncWorkspaceError; set only while the mobile authority is unchanged.',
    'w.setError(':
        'Workspace error is a one-shot toast, consumed by syncWorkspaceError; set only while the mobile authority is unchanged.',
    'w.setError(userErrorText(e, where: \'open agent conversation\'));':
        'Workspace error is a one-shot toast, consumed by syncWorkspaceError; set only while the workspace authority is unchanged.',
  },
  'apps/raft_flutter/lib/main.dart': {
    'String? selectorError;':
        'Cleared when a directory load, server choice or create starts, when the selector is reopened; set only for the current rootRequest.',
    'String? bootError;':
        'Cleared when a new sign-in succeeds (new client installed).',
    'workspace?.setError(message);':
        'One-shot toast for a failed share hand-off, consumed by WorkspaceView.',
    'w.setError(\'Could not join this channel.\');':
        'One-shot toast, raised only while the share destination is still current (stillHere).',
    'w.setError(':
        'One-shot toast, raised only while the server selection request is current.',
  },
  'apps/raft_flutter/lib/platform/app_icon.dart': {
    'String? error;':
        'Clears on the next successful refresh or when a selection starts.',
  },
  'apps/raft_flutter/lib/platform/app_update.dart': {
    'bool _loggedFailure = false, _disposed = false;':
        '_loggedFailure only de-duplicates a log line (never shown in the UI); _disposed is lifecycle state.',
  },
  'apps/raft_flutter/lib/platform/content_coordinator.dart': {
    'w.setError(':
        'Workspace-level w.error is shown once as a toast by workspace_view.syncWorkspaceError and cleared there (self-dismissing).',
  },
  'apps/raft_flutter/lib/platform/linux_uri_scheme.dart': {
    'String? error;':
        'Clears whenever the registration is re-inspected, registered or removed (_inspect/_register/unregister).',
  },
  'apps/raft_flutter/lib/platform/native_notifications.dart': {
    'String? error, backgroundError;':
        'error clears when the principal changes (bind), on the next successful permission check/enable/delivery; backgroundError is set by its owner via setBackgroundError(null).',
  },
  'packages/raft_ui/lib/src/add_computer_dialog.dart': {
    'String error = \'\';':
        'Cleared when the next register attempt starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/agent_dialogs.dart': {
    'String? error;':
        'Cleared when the next save starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/community_agreement_dialog.dart': {
    'String error = \'\';':
        'Cleared when the next agree attempt starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/computer_detail.dart': {
    'String nameError = \'\';':
        'Cleared when name editing starts, the name is typed, a save starts or another computer is shown.',
    'String descriptionError = \'\';':
        'Cleared when description editing starts, the text is typed, a save starts or another computer is shown.',
    'String bulkError = \'\';':
        'Cleared when a bulk action starts, selection is cancelled or another computer is shown.',
  },
  'packages/raft_ui/lib/src/form_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts, validation included; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/invite_human_dialog.dart': {
    'String? error;':
        'Cleared when the next send starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/message_body.dart': {
    'String? copyError;':
        'Mermaid toolbar message: cleared by a successful copy, at the start of every export and when the source changes.',
    'String? error;':
        'Code block copy message: cleared by a successful copy and when the code changes.',
  },
  'packages/raft_ui/lib/src/report_issue_dialog.dart': {
    'String? error;':
        'Cleared when the next submit starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/secret_view.dart': {
    'String? notice;':
        'Cleared two seconds after it is raised, when the next copy starts or when the credential value changes.',
  },
  'packages/raft_ui/lib/src/settings_controls.dart': {
    'String? error;':
        'Cleared when the next confirm starts; the dialog state is dropped when it closes.',
  },
  'packages/raft_ui/lib/src/sos_dialog.dart': {
    'String? error;':
        'Cleared when the next stop or resume starts; the dialog state is dropped when it closes.',
  },
};
