#!/usr/bin/env python3
"""Web PAGE INVENTORY vs Flutter parity coverage -> docs/parity-page-inventory.md.

The inventory is data (ROWS below, one row per user-facing Web page / panel /
modal / drawer / sheet / popover / empty-or-error state worth a screen); the
document is generated from it so the counts never drift from the rows:

  python3 tool/parity-ext/inventory.py            # rewrite docs/parity-page-inventory.md
  python3 tool/parity-ext/inventory.py --check    # fail when the doc is stale or an id is unknown

Coverage vocabulary per applicable platform (D = desktop 1280, P = phone 390):
  ok       a case exists (official id, or extension id on the default theme brutal-light)
  partial  the surface only appears inside other cases / only some of its states have a case
  wip      a case is being added on another branch (named in the row note)
  MISSING  no case
  n/a      the surface does not exist on that platform
  excluded the page is dead, obsolete or not shown to normal users (`excl=(reason, evidence)`): it drops out of the
           missing counts and the ranking. Reasons: obsolete | flag-off | host-only | dev-only | duplicate | superseded.
           Reachability evidence is from the pinned Web source only (no git history exists there: one release commit).
  verify   (`verify=` text, not a state) reachability is unclear or the page may not apply to a native client; the page
           stays in the counts and is listed in the "Verify" section.

Extension ids are written without the theme suffix and may be globs; they are
validated against the manifest the builders generate (tests/test_parity_ext.py).
Official ids (phone only, react__android) are validated against
packages/visual-testing/shared/sharedCases.json when the raft-source checkout is present.
"""
import fnmatch
import json
import os
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DOC = ROOT / 'docs/parity-page-inventory.md'
RAFT_SOURCE = pathlib.Path(os.environ.get(
    'PARITY_RAFT_SOURCE', '/home/kevinzhow/.slock/agents/9a92b742-8942-488c-8635-67d224ec54ab/work/raft-source'))
W = 'packages/web/src/'

OFFICIAL_UI = ('components.tokens.palette', 'components.ui.*')


class Row:
    def __init__(self, num, name, web, ap, off=(), d=(), p=(), prio=2, note='', d_state=None, p_state=None,
                 excl=None, verify=None):
        self.num, self.name, self.web, self.ap = num, name, web, ap
        self.excl, self.verify = excl, verify  # excl = (reason, evidence)
        self.off, self.d, self.p = tuple(off), tuple(d), tuple(p)
        self.prio, self.note = prio, note
        self.d_state, self.p_state = d_state, p_state  # explicit override: 'partial' | 'wip'

    def state(self, platform):
        """-> ok | partial | wip | MISSING | n/a | excluded for 'D' or 'P'."""
        if platform not in self.ap:
            return 'n/a'
        if self.excl:
            return 'excluded'
        override = self.d_state if platform == 'D' else self.p_state
        has = bool(self.d) if platform == 'D' else bool(self.off or self.p)
        if override and (has or override == 'wip'):
            return override
        return 'ok' if has else 'MISSING'


def R(*args, **kwargs):
    return Row(*args, **kwargs)


# (section title, intro, rows)
SECTIONS = [
    ('1. Auth, onboarding and public entry', 'App.tsx AppShell / ServerResolver, components/auth, components/onboarding, pages/*', [
        R('1.01', 'Auth bootstrap status (loading / restoring session)', 'App.tsx AuthBootstrapStatus', 'DP', d=['components.auth-pages.desktop.bootstrap.*'], p=['components.auth-pages.mobile.bootstrap.*'], prio=3,
          note='Flutter showed a spinner (no text); now the same cream splash.'),
        R('1.02', 'Login (default)', 'components/auth/LoginPage.tsx', 'DP',
          off=['screens.auth.login'], d=['components.auth-ext.desktop.login.default'], p=['components.auth-ext.mobile.login.default']),
        R('1.03', 'Login states (invalid email, missing password, credentials error, filled, signing in)', 'components/auth/LoginPage.tsx', 'DP',
          off=['screens.auth.login.signing'], d=['components.auth-ext.desktop.login.*'], p=['components.auth-ext.mobile.login.*']),
        R('1.04', 'Social sign-in buttons (Google / GitHub / Apple, hover)', 'components/auth/SocialProviderButton.tsx', 'DP',
          d=['components.auth-ext.desktop.social.*', 'components.auth-ext.desktop.login.social'],
          p=['components.auth-ext.mobile.social.*', 'components.auth-ext.mobile.login.social']),
        R('1.05', 'Register', 'components/auth/RegisterPage.tsx', 'DP', off=['components.auth.register.inputs'],
          d=['components.auth-pages.desktop.register.default'], p=['components.auth-pages.mobile.register.default'], prio=2),
        R('1.06', 'Register states (validation errors, legal consent unchecked, submit error)', 'components/auth/RegisterPage.tsx, LegalAcceptanceCheckbox.tsx', 'DP',
          d=['components.auth-pages.desktop.register.*', '!*.register.default'], p=['components.auth-pages.mobile.register.*', '!*.register.default'], prio=2),
        R('1.07', 'Forgot password (default, filled, sent, error)', 'components/auth/ForgotPasswordPage.tsx', 'DP',
          off=['screens.auth.forgot-password'], d=['components.auth-ext.desktop.forgot.*'], p=['components.auth-ext.mobile.forgot.*']),
        R('1.08', 'Reset password (default, filled, too short, mismatch, error, done)', 'components/auth/ResetPasswordPage.tsx', 'DP',
          d=['components.auth-ext.desktop.reset.*'], p=['components.auth-ext.mobile.reset.*']),
        R('1.09', 'Email verification (link wait, manual code, resent, errors)', 'components/auth/EmailVerificationPage.tsx', 'DP',
          d=['components.auth-ext.desktop.verify.*'], p=['components.auth-ext.mobile.verify.*']),
        R('1.10', 'Account identity (profile) setup', 'components/auth/AccountIdentitySetupPage.tsx', 'DP',
          off=['screens.auth.profile-setup'], d=['components.auth-pages.desktop.identity.*'], p=['components.auth-pages.mobile.identity.*'], prio=2),
        R('1.11', 'Social auth callback (loading / error)', 'components/auth/SocialAuthCallbackPage.tsx', 'DP', prio=3),
        R('1.12', 'Invite accept (email invite link; signed-out and signed-in variants, expired / invalid)', 'components/auth/InviteAcceptPage.tsx', 'DP',
          d=['components.auth-pages.desktop.invite.*'], p=['components.auth-pages.mobile.invite.*'], prio=2,
          note='First screen every invited user sees. Flutter: InviteAcceptView / RaftInviteAcceptPage, opened by /join/<token>, ?invite=, raft://v1/join/<token> and the Join workspace dialog; Sign In / Create Account keep the token until the account is ready.'),
        R('1.13', 'Choose server', 'components/auth/ServerSelector.tsx', 'DP',
          off=['screens.auth.choose-server', 'screens.home.choose-server'],
          d=['components.auth-ext.desktop.server.choose'], p=['components.auth-ext.mobile.server.choose']),
        R('1.14', 'Create first server (no server yet)', 'components/auth/ServerSelector.tsx, OnboardingCreateShell.tsx, ServerCreatePreview.tsx', 'DP',
          d=['components.auth-pages.desktop.server.create-first*'], p=['components.auth-ext.mobile.server.create-first*'], prio=2),
        R('1.15', 'Create another server', 'components/auth/ServerSelector.tsx', 'DP',
          d=['components.auth-ext.desktop.server.create-more*'], p=['components.auth-ext.mobile.server.create-more*']),
        R('1.16', 'Server access denied / server not found', 'App.tsx ServerAccessDeniedPage', 'DP', d=['components.auth-pages.desktop.server-denied.*'], p=['components.auth-pages.mobile.server-denied.*'], prio=2,
          note='Flutter: RaftServerAccessDeniedPage; an unknown /s/<slug> keeps its URL, names the fallback server and redirects after 3 s.'),
        R('1.17', 'Servers loading and joining-community splash', 'App.tsx ServerResolver, ServerSelectionPage', 'DP', d=['components.auth-pages.desktop.servers.*'], p=['components.auth-pages.mobile.servers.*'], prio=3,
          note='Flutter: /s/community for a non-member joins on arrival behind the "Joining community…" splash (community_join.dart); community-cn has no Flutter page.'),
        R('1.18', 'Community agreement dialog (join a community server)', 'components/server/CommunityAgreementDialog.tsx', 'DP', d=['components.auth-pages.desktop.community-agreement.*'], p=['components.auth-pages.mobile.community-agreement.*'], prio=2,
          note='Flutter: RaftCommunityAgreementDialog (agreement from the 409 receipt) over the not-found page for /s/community, and from the Help menu Join Community.'),
        R('1.19', 'Public server preview (signed-out channel list + read-only messages, join / sign-in banner, unavailable)', 'pages/PublicServerPage.tsx', 'DP', prio=2),
        R('1.20', 'Public server: join confirm dialog and guest join', 'pages/PublicServerPage.tsx', 'DP', prio=3),
        R('1.21', 'Server setup survey (default, answered, other, save failed)', 'components/onboarding/ServerSetupSurveyStep.tsx', 'DP',
          d=['components.auth-ext.desktop.setup.survey*'], p=['components.auth-ext.mobile.setup.survey*']),
        R('1.22', 'Server setup: connect a computer (not connected, connecting, ready, not ready, offline recovery)', 'components/onboarding/ServerSetupComputerRuntimeStep.tsx', 'DP',
          d=['components.auth-ext.desktop.setup.computer-*'], p=['components.auth-ext.mobile.setup.computer-*']),
        R('1.23', 'Server setup: handoff step (default, starting)', 'components/onboarding/ServerSetupHandoffStep.tsx', 'DP',
          d=['components.auth-ext.desktop.setup.handoff*'], p=['components.auth-ext.mobile.setup.handoff*']),
        R('1.24', 'Server setup projection gate (loading, error, dedicated native surface, footer)', 'components/onboarding/ServerSetupProjectionGate.tsx, SetupSessionFooter.tsx', 'DP',
          d=['components.auth-pages.desktop.setup-gate.*'], p=['components.auth-pages.mobile.setup-gate.*'], prio=3,
          note='Flutter: deferred-setup resume bar (RaftSetupResumeBar in ServerSetupGate). The dedicated-surface cases (loading / unavailable / load failed / complete) stay without a Flutter widget: that page exists for native WebView hosts, the app renders setup natively.'),
        R('1.25', 'Device login (/login/device): enter code, approve, approved, invalid / expired / used code', 'pages/DeviceLoginPage.tsx', 'DP', prio=2,
          note='The CLI / computer sign-in confirmation.'),
        R('1.26', 'App login handoff (/login/app)', 'pages/AppLoginPage.tsx', 'DP', prio=3),
        R('1.27', 'Login with Raft setup (/login-with-raft/setup, scope consent)', 'pages/HumanLoginSetupPage.tsx, oauth/RequestedScopeConsent.tsx', 'DP', prio=3),
        R('1.28', 'Integration invite (/integration-invite): install app, not found, needs admin', 'pages/IntegrationInvitePage.tsx', 'DP', prio=3),
        R('1.29', 'Agent connection callback (connected / denied / expired / foreign account)', 'pages/AgentConnectionCallbackPage.tsx', 'DP', prio=3),
        R('1.30', 'Mobile download chooser (/download)', 'pages/MobileDownloadChooserPage.tsx', 'DP', prio=3),
        R('1.31', 'Chinese community page', 'pages/ChineseCommunityPage.tsx', 'DP', prio=3),
        R('1.32', 'PWA install prompt (iOS Safari add-to-home steps)', 'components/pwa/PwaInstallPrompt.tsx', 'P', prio=3),
        R('1.33', 'Root error fallback (app crashed, reload)', 'components/errors/RootErrorFallback.tsx', 'DP', d=['components.auth-pages.desktop.root-error.*'], p=['components.auth-pages.mobile.root-error.*'], prio=2,
          note='Flutter: RaftRootErrorFallback under RootErrorBoundary (release builds; debug keeps the framework error screen).'),
        R('1.34', 'App update gate (stale build, refresh to continue)', 'components/errors/AppUpdateGate.tsx', 'DP', prio=3),
    ]),
    ('2. Shell and navigation', 'components/layout (MainLayout, LeftRail, Sidebar, NotificationCenter, MobileBottomBarStack), components/ui', [
        R('2.01', 'Desktop rail + sidebar, chat mode (default, empty, loading, custom sections, sorted, collapsed, row hover)', 'components/layout/LeftRail.tsx, Sidebar.tsx', 'D',
          d=['components.shell.desktop.sidebar.*']),
        R('2.02', 'Phone Home: sidebar as the home list (default, collapsed, loading)', 'components/layout/Sidebar.tsx (mobileInline)', 'P',
          off=['screens.home.index', 'screens.home.loading'], p=['components.shell.mobile.sidebar.default', 'components.shell.mobile.sidebar.collapsed']),
        R('2.03', 'Phone bottom tab bar', 'components/layout/MobileBottomBarStack.tsx', 'P', off=['components.navigation.tabbar.states']),
        R('2.04', 'Phone titlebar (server unread, notification trigger)', 'components/layout/Sidebar.tsx, NotificationTrigger.tsx', 'P', off=['components.home.titlebar.states']),
        R('2.05', 'Notification center (popover on desktop, sheet on phone)', 'components/layout/NotificationCenter.tsx', 'DP',
          off=['components.home.notification-center.states'], prio=2, note='Desktop: no case.'),
        R('2.06', 'Server switcher menu', 'components/ui/ServerSwitcherMenu.tsx', 'DP',
          off=['components.home.server-switcher.open'], d=['components.shell.desktop.server.menu']),
        R('2.07', 'Rail help menu (docs, mobile app, community)', 'components/layout/LeftRail.tsx', 'D', d=['components.shell.desktop.rail.help-menu']),
        R('2.08', 'Row context menus (channel, muted channel, DM, agent DM, section, custom section, surface, Move to section)', 'components/layout/Sidebar.tsx', 'DP',
          d=['components.shell.desktop.menu.*'], p=['components.shell.mobile.menu.*'], note='Phone: channel row menu only.', p_state='partial'),
        R('2.09', 'Section sort menu', 'components/layout/Sidebar.tsx', 'DP', d=['components.shell.desktop.sidebar.sort-menu'], p=['components.shell.mobile.sidebar.sort-menu']),
        R('2.10', 'Section dialogs (new, rename, delete)', 'components/layout/SidebarSectionDialog.tsx', 'DP',
          d=['components.shell.desktop.dialog.*-section'], prio=3, note='Phone: no case.'),
        R('2.11', 'Section emoji picker', 'components/layout/SidebarSectionEmojiPicker.tsx', 'DP', prio=3),
        R('2.12', 'Archive channel confirm (from the sidebar menu)', 'components/layout/Sidebar.tsx', 'DP', d=['components.shell.desktop.dialog.archive-channel'], prio=3,
          note='Phone: no case.'),
        R('2.13', 'Conversation finder ("Find a conversation..." box and results)', 'components/layout/SidebarConversationFinder.tsx', 'DP', prio=2),
        R('2.14', 'Live agent activity bar (tool finished, working, thinking, compacting, long)', 'components/layout/LiveAgentActivityBar.tsx', 'DP',
          d=['components.liveactivity.desktop.*'], p=['components.liveactivity.mobile.*']),
        R('2.15', 'Activity page frame (rail + inbox column edge)', 'components/layout/MainLayout.tsx', 'DP',
          d=['components.shell.desktop.activity.frame'], p=['components.shell.mobile.activity.frame']),
        R('2.16', 'Confirm dialogs (danger, warning, acknowledge)', 'components/ConfirmDialog.tsx', 'DP',
          d=['components.shell.desktop.confirm.*'], p=['components.shell.mobile.confirm.*']),
        R('2.17', 'Banner, empty state, bottom sheet, overflow sheet', 'components/ui/Banner.tsx, EmptyState.tsx, BottomSheet.tsx, OverflowSheet.tsx', 'DP',
          d=['components.shell.desktop.banner.*', 'components.shell.desktop.empty.*', 'components.shell.desktop.bottomsheet.*', 'components.shell.desktop.overflow.*'],
          p=['components.shell.mobile.banner.*', 'components.shell.mobile.empty.*', 'components.shell.mobile.bottomsheet.*', 'components.shell.mobile.overflow.*']),
        R('2.18', 'Toasts (success, error, info, plain)', 'components/LocalizedToastProvider.tsx', 'DP',
          d=['components.shell.desktop.toast.*'], p=['components.shell.mobile.toast.*']),
        R('2.19', 'Announcement modal (single, multi-page, rich, long, overlay)', 'components/AnnouncementModal.tsx', 'DP',
          d=['components.announcements.desktop.*'], p=['components.announcements.mobile.*']),
        R('2.20', 'UI library primitives (button, card, badge, form field, checkbox, select, menu item, ...; shared by both platforms)', 'packages/ui (raft-ui)', 'P',
          off=OFFICIAL_UI, note='Rendered by the same Flutter raft_ui widgets on desktop; the shell primitive cases above cover the desktop sizes.'),
        R('2.21', 'Workspace grid mode (Labs: multi-panel desktop layout)', 'components/workspace/*, MainLayout.tsx', 'D', prio=3, note='Behind the Labs flag.'),
    ]),
    ('3. Channel and DM conversation', 'components/message (ChatPanel, MessageItem, MessageTimeline, MessageInput, ThreadPanel), components/channel', [
        R('3.01', 'Channel screen (rail + sidebar + header + timeline + composer composed)', 'components/layout/MainLayout.tsx ChannelRoute, message/ChatPanel.tsx', 'DP',
          off=['screens.thread.channel'], d=['components.screens-ext.channel.desktop.full'], p=['components.screens-ext.channel.mobile.full'], prio=1,
          note='Composed 1280x800 and phone screens with a realistic message mix (markdown, code, mention, reactions, inline thread, system line).'),
        R('3.02', 'DM screen (human DM, agent DM composed)', 'components/layout/MainLayout.tsx DmRoute', 'DP',
          off=['screens.thread.dm'], d=['components.screens-ext.dm.desktop.*'], p=['components.screens-ext.dm.mobile.agent'], prio=1,
          note='Human and agent DM screens composed at 1280x800; phone has the agent DM.'),
        R('3.03', 'Desktop with no conversation selected ("Select a channel" empty main)', 'components/message/ChatPanel.tsx (channel=null)', 'D', prio=2),
        R('3.04', 'Conversation header (channel, private, DM human / agent, description clamp, search button, Chat / Files / Tasks tabs)', 'components/message/ChatPanel.tsx, channel/ChannelDescription.tsx', 'DP',
          off=['components.thread.header.states'], d=['components.channelheader.desktop.*'], p=['components.channelheader.mobile.*']),
        R('3.05', 'Timeline (date dividers, empty channel, loading, history limit banner, beginning of messages, system groups, back to bottom)', 'components/message/MessageTimeline.tsx, DateDivider.tsx, HistoryLimitBanner.tsx, SystemMessageGroupDisclosure.tsx', 'DP',
          d=['components.thread-ext.timeline.desktop.*'], p=['components.thread-ext.timeline.mobile.*']),
        R('3.06', 'Channel state banners (archived + Unarchive, read-only quota + upgrade, guest read-only + Join channel, joint locked, over-limit grace, message not found, channel unavailable)', 'components/message/ChatPanel.tsx', 'DP', prio=2),
        R('3.07', 'Channel Files tab (list; empty, loading, error, load more)', 'components/message/ChannelFilesPanel.tsx', 'DP',
          off=['components.thread.files.list'], prio=2, note='Desktop: no case. Phone: populated list only.'),
        R('3.08', 'Channel Tasks tab (TasksPanel scoped to the channel)', 'components/message/ChatPanel.tsx, task/TasksPanel.tsx', 'DP', prio=3,
          note='Same panel as the Tasks page (6.01) minus the channel column.'),
        R('3.09', 'Message row (human, agent, system, deleted, rich markdown, code, long inline code, links, task chips)', 'components/message/MessageItem.tsx, markdown/*', 'DP',
          off=['components.thread.message.row', 'components.thread.message-row.*'], d=['components.thread-ext.message.toolbar.desktop'], prio=2,
          note='Desktop: rows only appear inside toolbar / forward / mermaid cases.', d_state='partial'),
        R('3.10', 'Message hover toolbar and quick reaction picker', 'components/message/MessageHoverToolbar.tsx', 'D',
          d=['components.thread-ext.message.toolbar*', 'components.thread-ext.message.picker*']),
        R('3.11', 'Message context menu (default message, task message)', 'components/message/MessageItem.tsx', 'DP',
          off=['components.thread.message-menu.*'], prio=2, note='Desktop: right-click menu has no case.'),
        R('3.12', 'Reaction chips row and reactors tooltip', 'components/message/MessageItem.tsx', 'DP', prio=3),
        R('3.13', 'Message selection mode (toolbar, share-as-image lightbox)', 'components/message/SelectModeToolbar.tsx, SelectShareLightbox.tsx', 'DP',
          off=['components.thread.message-share.*'], prio=3, note='Desktop: no case.'),
        R('3.14', 'Forward composer (destinations, note, send)', 'components/message/ForwardComposerDesktop.tsx, ForwardComposerMobile.tsx', 'DP',
          off=['components.thread.forward-modal'], prio=2, note='Desktop dialog: no case.'),
        R('3.15', 'Forwarded bundle card in the timeline (single, multi, expanded, thread, restricted)', 'components/message/ForwardedBundleCard.tsx', 'DP',
          d=['components.thread-ext.message.forward-*', '!*.mobile'], p=['components.thread-ext.message.forward-*.mobile']),
        R('3.16', 'Quoted message permalink preview and linked-message fallbacks', 'components/message/QuotedMessagePermalinkPreview.tsx', 'DP', prio=3),
        R('3.17', 'Mermaid diagram card (toolbar, code view, diagram view)', 'components/mermaid/MermaidDiagram.tsx', 'DP',
          d=['components.thread-ext.message.mermaid-*', '!*.mobile'], p=['components.thread-ext.message.mermaid-toolbar.mobile']),
        R('3.18', 'Mermaid full-screen viewer', 'components/mermaid/MermaidDiagramViewer.tsx', 'DP', prio=3),
        R('3.19', 'Composer (empty, draft with send enabled)', 'components/message/MessageInput.tsx', 'DP',
          off=['components.thread.composer.empty', 'components.thread.composer.states'],
          d=['components.thread-ext.thread.desktop.composer'], p=['components.thread-ext.thread.mobile.composer']),
        R('3.20', 'Composer @mention and #channel suggestion popovers', 'components/message/MessageInput.tsx, mentionCandidates.ts', 'DP',
          off=['components.thread.composer.member-suggestions', 'components.thread.composer.channel-suggestions'],
          d=['components.screens-ext.composer.desktop.*'], prio=1, note='Desktop: @mention (not-in-channel group) and #channel popovers over the composed channel screen.'),
        R('3.21', 'Composer "As task" mode', 'components/message/MessageInput.tsx', 'DP', off=['components.thread.composer.as-task-selected'], prio=2, note='Desktop: no case.'),
        R('3.22', 'Composer pending-mention action strip (agent outside the channel)', 'components/message/PendingMentionActionStrip.tsx', 'DP',
          off=['components.thread.composer.pending-mention-actions'], prio=3, note='Desktop: no case.'),
        R('3.23', 'Composer attachments (image, file, mixed, checking, uploading, failed, over size / count, drag over)', 'components/message/MessageInput.tsx, AttachmentChip.tsx', 'DP',
          off=['components.thread.composer.image-preview', 'components.thread.composer.file-previews'],
          d=['components.composerattachments.desktop.*'], p=['components.composerattachments.mobile.*']),
        R('3.24', 'Composer warnings (agent stopped delivery, unresolved mentions, conversion in progress, archived badge)', 'components/message/MessageInput.tsx', 'DP', prio=3),
        R('3.25', 'Attachment viewers (image lightbox + gallery, text / csv / xlsx / markdown, html sandbox, comments panel)', 'components/message/attachmentPreviewSurfaces.tsx, ImageLightbox.tsx', 'DP',
          off=['components.thread.comment-anchor'], d=['components.thread-ext.attachment.*', '!*.mobile'], p=['components.thread-ext.attachment.*.mobile']),
        R('3.26', 'Audio, video, PDF and diff / patch previews', 'components/message/MessageItem.tsx, ui/CrossOriginPdfFrame.tsx', 'DP', prio=3,
          d=['components.thread-ext.attachment.doc.header-pdf'], note='Only the PDF header has a case.', d_state='partial', p_state=None),
        R('3.27', 'Profile preview card (hover / tap on an avatar: agent runtime, model, computer; human)', 'components/message/ProfilePreviewCardContent.tsx', 'DP', prio=2),
        R('3.28', 'Mention hover activity preview', 'components/message/MentionHoverActivityPreview.tsx', 'D', prio=3),
        R('3.29', 'External identity preview card and detail panel', 'components/message/ExternalIdentityPreviewCard.tsx, profile/ExternalIdentityDetailPanel.tsx', 'DP', prio=3),
        R('3.30', 'Profile side panel (open from a sender)', 'components/profile/ProfilePanel.tsx', 'D', prio=2),
        R('3.31', 'Action card in a message (install app, create agent, channel members, owner recovery)', 'components/actions/ActionCard.tsx', 'DP', prio=2),
        R('3.32', 'SOS dialog (confirm, stopped, guidance)', 'components/message/SOSDialog.tsx', 'DP',
          d=['components.thread-ext.message.sos-*', '!*.mobile'], p=['components.thread-ext.message.sos-confirm.mobile']),
        R('3.33', 'Notification activation banner', 'components/message/NotificationActivationBanner.tsx', 'DP',
          d=['components.thread-ext.message.banner.desktop'], p=['components.thread-ext.message.banner.mobile']),
        R('3.34', 'Translation in message rows (translating, original / bilingual, unavailable)', 'components/message/MessageItem.tsx', 'DP', prio=3,
          note='The Language & Region settings page has cases (9.05).'),
        R('3.35', 'Thread panel (replies, empty, loading, history limited, overflow menu)', 'components/message/ThreadPanel.tsx, ThreadOverflowMenu.tsx', 'DP',
          d=['components.thread-ext.thread.desktop.*'], p=['components.thread-ext.thread.mobile.*']),
        R('3.36', 'Inline thread replies preview', 'components/message/InlineThreadReplies.tsx', 'DP',
          d=['components.thread-ext.inline.desktop.*'], p=['components.thread-ext.inline.mobile.*']),
        R('3.37', 'Thread load failed (retry), guest read-only, joint locked', 'components/message/ThreadPanel.tsx', 'DP', prio=3),
        R('3.38', 'In-thread search (search bar, next / previous match)', 'components/message/ThreadPanel.tsx', 'DP', prio=3),
        R('3.39', 'Thread agent followers (list, remove, undo)', 'components/thread/ThreadAgentFollowers.tsx', 'DP', prio=3),
        R('3.40', 'Channel overflow menu (members summary, inline edit, stop all agents confirm)', 'components/channel/ChannelOverflowMenu.tsx', 'DP', prio=3),
    ]),
    ('4. Channel management dialogs', 'components/channel, components/agent/ChannelMembers.tsx', [
        R('4.01', 'Create channel dialog (public / private, members picker)', 'components/channel/CreateChannelDialog.tsx', 'DP',
          off=['components.home.create-channel.dialog'], d=['components.dialogs.desktop.create-channel'], prio=1),
        R('4.02', 'Create channel states (name error, archived name held + Unarchive, plan limit, creating)', 'components/channel/CreateChannelDialog.tsx', 'DP', prio=3),
        R('4.03', 'Create shared (joint) channel dialog', 'components/channel/CreateJointChannelDialog.tsx', 'DP', prio=3),
        R('4.04', 'Channel settings drawer (owner, admin, member, guest, private, archived, dirty, #all, DM, members overflow, tall windows)', 'components/channel/EditChannelDialog.tsx, agent/ChannelMembers.tsx', 'DP',
          off=['components.channel.settings.panel'], d=['components.channelsettings.desktop.*'], p=['components.channelsettings.mobile.*']),
        R('4.05', 'Channel settings confirmations (leave, archive, make private, hide #all, delete, unsaved changes)', 'components/channel/EditChannelDialog.tsx', 'DP',
          d=['components.channelsettings.desktop.confirm-*', 'components.channelsettings.desktop.unsaved-prompt'], p=['components.channelsettings.mobile.confirm-delete'],
          note='Phone: delete confirm only.', p_state='partial'),
        R('4.06', 'Add members to a channel', 'components/channel/AddMembersDialog.tsx', 'DP',
          off=['components.channel.members.add-panel'], prio=2, note='Desktop dialog: no case.'),
        R('4.07', 'Remove channel member confirm', 'components/channel/useChannelMemberRemoval.tsx', 'DP', prio=3),
    ]),
    ('5. Search, Activity and Saved', 'components/search, components/thread/ThreadsInbox.tsx, components/saved', [
        R('5.01', 'Search overlay (desktop Cmd-K): home, recents, query, exact, selected, no results, loading, error, thread group, sender filter', 'components/search/SearchOverlay.tsx, MessageSearchPage.tsx (overlay presentation)', 'D',
          d=['components.search-overlay.*']),
        R('5.02', 'Search results page (phone Search tab; desktop "view all results")', 'components/search/MessageSearchPage.tsx', 'DP',
          off=['components.home.search.results'], prio=2, note='Desktop full-page presentation: no case.'),
        R('5.03', 'Search channel filter dropdown', 'components/search/MessageSearchPage.tsx', 'DP',
          off=['components.home.search.channel-dropdown'], prio=3, note='Desktop: no case (overlay filters-sender only).'),
        R('5.04', 'Search page states (history + frequent, searching, no results, error + retry, load more, query too broad, beyond plan history)', 'components/search/MessageSearchPage.tsx', 'DP', prio=2,
          note='Overlay variants have desktop cases (5.01); the full-page variants have none.'),
        R('5.05', 'Activity inbox, populated list', 'components/thread/ThreadsInbox.tsx', 'DP',
          off=['components.home.activity.results', 'screens.home.activity'], d=['components.screens-ext.activity.desktop.list'], prio=1,
          note='Desktop: rail plus the 560px Activity master column with the official three-row inbox fixture.'),
        R('5.06', 'Activity empty / loading / error', 'components/thread/ThreadsInbox.tsx', 'DP',
          d=['components.members-ext.activity.*', 'components.thread-ext.inbox.desktop.empty'], prio=3, note='Phone: no case.'),
        R('5.07', 'Activity filters (All / Mentions / Unread)', 'components/thread/ThreadsInbox.tsx', 'DP', prio=2),
        R('5.08', 'Activity item context menu (mark read / unread, follow, done)', 'components/thread/ThreadsInbox.tsx', 'DP', prio=3),
        R('5.09', 'Saved messages list', 'components/saved/SavedPanel.tsx', 'DP',
          off=['components.home.saved.results', 'screens.home.saved'], prio=2, note='Desktop: no populated list case.'),
        R('5.10', 'Saved empty / loading / error', 'components/saved/SavedPanel.tsx', 'DP', d=['components.members-ext.saved.*'], prio=3, note='Phone: no case.'),
        R('5.11', 'Saved item actions (copy link, copy Markdown, remove)', 'components/saved/SavedPanel.tsx', 'DP', prio=3),
        R('5.12', 'Activity Done and Saved views, channel filter, sort, in-list search', 'components/thread/ThreadsInbox.tsx', 'DP', prio=2),
    ]),
    ('6. Tasks', 'components/task', [
        R('6.01', 'Tasks page (desktop board / phone list)', 'components/task/TasksPanel.tsx', 'DP',
          off=['screens.tasks.index', 'components.tasks.panel.states'], d=['components.taskspage.desktop.*'], p=['components.taskspage.mobile.*']),
        R('6.02', 'Tasks page, empty lanes', 'components/task/TasksPanel.tsx', 'DP', d=['components.wp6.tasks.empty-lanes', 'components.wp6.tasks.empty-lanes-expanded'], p=['components.wp6.tasks.empty-lanes-mobile']),
        R('6.03', 'Task filter segmented control', 'components/task/TaskFilterSegmentedControl.tsx', 'DP', d=['components.wp6.tasks.filter*', '!*-mobile'], p=['components.wp6.tasks.filter*-mobile']),
        R('6.04', 'Task filters (assignee, creator, channels popovers; clear all; filtered-empty)', 'components/task/TasksPanel.tsx', 'DP', prio=2),
        R('6.05', 'Tasks list / board view toggle (the non-default view)', 'components/task/TasksPanel.tsx', 'D', prio=3),
        R('6.06', 'Task status menu', 'components/task/StatusBadge.tsx, TasksPanel.tsx', 'DP', off=['components.tasks.status-menu'], prio=3, note='Desktop: no case.'),
        R('6.07', 'Create task dialog (default, filled, batch, title required)', 'components/task/CreateTaskDialog.tsx', 'DP',
          d=['components.wp6.tasks.create-dialog*', '!*-mobile'], p=['components.wp6.tasks.create-dialog*-mobile']),
        R('6.08', 'Task detail (thread modal with properties, replies, history; every status)', 'components/task/TaskProperties.tsx, message/ThreadPanel.tsx', 'DP',
          off=['screens.thread.task-thread'], d=['components.taskdetail.desktop.*'], p=['components.taskdetail.mobile.*']),
        R('6.09', 'Legacy (v1) task panel, read-only', 'components/task/LegacyTaskPanel.tsx', 'DP', prio=3),
        R('6.10', 'Tasks loading and load-more states', 'components/task/TasksPanel.tsx', 'DP', prio=3),
    ]),
    ('7. Members, humans and agents', 'components/member, components/agent, components/agentMigration, components/handoff', [
        R('7.01', 'Members list (agents grouped by computer, humans; selected, hover, collapsed)', 'components/layout/Sidebar.tsx (members mode)', 'DP',
          off=['screens.members.index'], d=['components.members-ext.list.default', 'components.members-ext.list.selected-*', 'components.members-ext.list.row-hover',
                                           'components.members-ext.list.group-collapsed', 'components.members-ext.list.humans-collapsed']),
        R('7.02', 'Members list empty / loading / error', 'components/layout/Sidebar.tsx (members mode)', 'DP',
          d=['components.members-ext.list.empty', 'components.members-ext.list.loading', 'components.members-ext.list.error'], prio=3, note='Phone: no case.'),
        R('7.03', 'Human profile (self, member, admin, guest, no description)', 'components/member/HumanDetailPanel.tsx', 'DP',
          off=['screens.members.human.profile'], d=['components.members-ext.human.*']),
        R('7.04', 'Human profile actions (edit role, remove member confirm)', 'components/member/HumanDetailPanel.tsx', 'DP',
          d=['components.members-ext.human.edit-role', 'components.members-ext.human.remove-confirm'], prio=3, note='Phone: no case.'),
        R('7.05', 'Role permission help dialog', 'components/member/RolePermissionHelpDialog.tsx', 'DP', prio=3),
        R('7.06', 'Invite human dialog (email / link tabs, guest role, seat limit)', 'components/member/InviteHumanDialog.tsx', 'DP',
          d=['components.members-ext.invite.*'], prio=2, note='Phone: no case.'),
        R('7.07', 'Avatar management (upload, view)', 'components/member/HumanDetailPanel.tsx, agent/AgentDetailPanel.tsx', 'DP',
          off=['components.members.avatar-management'], prio=3, note='Desktop: no case.'),
        R('7.08', 'Agent detail: Profile tab (computer online / offline / missing, no computer, daemon only, loading)', 'components/agent/AgentDetailPanel.tsx', 'DP',
          off=['components.members.agent-detail.profile', 'screens.members.agent-detail.profile', 'screens.members.agent-detail.profile.*'], d=['components.members-ext.agent.profile'],
          note='Desktop Agent-detail cases are being extended on cindy/alignment-audit.'),
        R('7.09', 'Agent detail: Activity tab (log, empty, loading, error)', 'components/agent/AgentActivityLog.tsx', 'DP',
          off=['screens.members.agent-detail.activity'], d=['components.members-ext.agent.activity*']),
        R('7.10', 'Agent detail: Chat tab (channels and DMs of the agent)', 'components/agent/AgentDetailPanel.tsx (AgentChatTab)', 'DP', prio=2,
          note='Desktop: in progress on cindy/alignment-audit. Phone: no case.', d_state='wip'),
        R('7.11', 'Agent detail: Reminders tab', 'components/agent/AgentRemindersSection.tsx', 'DP',
          off=['screens.members.agent-detail.reminders'], d=['components.members-ext.agent.reminders']),
        R('7.12', 'Agent detail: Workspace tab (files)', 'components/agent/AgentWorkspace.tsx', 'DP',
          off=['screens.members.agent-detail.workspace'], d=['components.members-ext.agent.workspace']),
        R('7.13', 'Agent detail: Apps tab', 'components/agent/AgentAppAccessTab.tsx', 'DP',
          off=['screens.members.agent-detail.apps'], d=['components.members-ext.agent.apps']),
        R('7.14', 'Agent detail: MCP tab (servers, empty, loading)', 'components/agent/AgentMcpTab.tsx', 'DP',
          d=['components.members-ext.agent.mcp*'], prio=2, note='Phone: no case.'),
        R('7.15', 'Reset / restart agent dialog (restart, reset session, full reset)', 'components/agent/ResetAgentDialog.tsx', 'DP',
          off=['components.members.agent-lifecycle-actions'], d=['components.members-ext.agent.reset-*']),
        R('7.16', 'Agent profile edit dialogs (name, description, role)', 'components/agent/AgentProfileEditDialog.tsx', 'DP',
          d=['components.members-ext.agent.edit-*'], prio=3, note='Phone: no case.'),
        R('7.17', 'Agent runtime config editor (modal)', 'components/agent/AgentDetailPanel.tsx, RuntimeConfigFields.tsx', 'DP', prio=2),
        R('7.18', 'Stop agent / delete agent confirmations and overflow menu', 'components/agent/AgentProfileOverflowMenu.tsx, AgentDetailPanel.tsx', 'DP', prio=2),
        R('7.19', 'Report issue dialog', 'components/agent/ReportIssueDialog.tsx', 'DP', prio=3),
        R('7.20', 'Agent unavailable panel (terminated or no access)', 'components/agent/AgentUnavailablePanel.tsx', 'DP', prio=2),
        R('7.21', 'Agent migration (move to another computer: dialog, progress, cancel, upgrade)', 'components/agentMigration/*', 'DP', prio=3, note='Behind a UI flag.'),
        R('7.22', 'Agent connections (provider sign-in for the agent)', 'components/agent/AgentConnections.tsx', 'DP', prio=3),
        R('7.23', 'External agent setup (token, setup tabs)', 'components/agent/ExternalAgentToken.tsx, ExternalSetupTabSegmentedControl.tsx', 'DP', prio=3),
        R('7.24', 'Create agent dialog (Codex, Claude, custom provider, built-in / Pi provider, onboarding, no computer, empty, name error)', 'components/agent/CreateAgentDialog.tsx', 'DP',
          off=['components.members.create-agent.*'], d=['components.dialogs.desktop.create-agent*'], prio=1),
        R('7.25', 'Member graph (/members/graph)', 'components/settings/MemberGraphSection.tsx', 'DP', prio=3),
        R('7.26', 'Handoff dialog (hand a local coding session to a new agent)', 'components/handoff/HandoffDialog.tsx, HandoffCreateFlow.tsx', 'D', prio=3, note='Desktop only (handoff.desktopOnly).'),
    ]),
    ('8. Computers', 'components/machine', [
        R('8.01', 'Computers list in the rail (rows, every row state, empty, loading, selected, hover)', 'components/layout/Sidebar.tsx (computers mode)', 'D',
          d=['components.computers.list.*']),
        R('8.02', 'Phone Computers page (list, needs-attention filter, empty, load error, refresh error)', 'components/machine/MobileComputersPanel.tsx', 'P', prio=2),
        R('8.03', 'Computer detail (header, identity, name / description edit, info, agents + bulk select, workspaces, service, recovery guide, offline, upgrading, disk low, legacy, delete)', 'components/machine/MachineDetailPanel.tsx', 'DP',
          d=['components.computers.detail.*'], prio=2, note='Phone: no case.'),
        R('8.04', 'Add computer dialog (type step, connect step)', 'components/machine/AddMachineDialog.tsx', 'DP',
          d=['components.computers.add-dialog*'], prio=3, note='Phone: no case. Connected, plan-limit and failed steps have no case.'),
        R('8.05', 'Computer dialogs (restart / reset agents, stop agents, delete workspace, delete blocked, delete)', 'components/machine/MachineDetailPanel.tsx', 'DP',
          d=['components.computers.dialog.*'], prio=3, note='Phone: no case.'),
        R('8.06', 'Runtime usage health chip and hover card', 'components/machine/RuntimeAccountUsageChip.tsx', 'D', d=['components.computers.detail.runtime-usage.*']),
    ]),
    ('9. Settings', 'components/settings/SettingsPanel.tsx (tabs in settingsNavigation.ts), WorkspaceSettingsModal.tsx', [
        R('9.01', 'Settings navigation (desktop rail by role / flags; phone root list)', 'components/layout/Sidebar.tsx (settings rail), settings/SettingsSidebarList.tsx, settingsNavigation.ts', 'DP',
          off=['components.settings.root.page'], d=['components.ext-settings.nav.*']),
        R('9.02', 'Account tab (profile card, display name, avatar, email, social links)', 'components/settings/SettingsPanel.tsx AccountSection', 'DP',
          off=['components.settings.account.page', 'components.settings.account.error-state'], d=['components.ext-settings.account.*'], prio=1),
        R('9.03', 'Account: change password, sign out', 'components/settings/SettingsPanel.tsx AccountSection', 'DP',
          d=['components.auth-pages.desktop.settings.account-*'], p=['components.auth-pages.mobile.settings.account-*'], prio=3),
        R('9.04', 'Account: workspace-mode card, usage data / storage', 'components/settings/UsageDataSettings.tsx, SettingsPanel.tsx', 'DP',
          off=['screens.settings.storage'], d=['components.wp6.settings.workspace-mode', 'components.wp6.settings.usage-data'],
          p=['components.wp6.settings.workspace-mode-mobile', 'components.wp6.settings.usage-data-mobile']),
        R('9.05', 'Language & Region (translation modes, display, provider missing, server off)', 'components/settings/SettingsPanel.tsx LanguageRegionSection', 'DP',
          d=['components.wp6.settings.language*', '!*-mobile'], p=['components.wp6.settings.language*-mobile']),
        R('9.06', 'Appearance tab (theme picker, text size)', 'components/settings/SettingsPanel.tsx AppearanceSection, AppearanceThemePicker.tsx', 'DP',
          off=['components.settings.appearance.page', 'screens.settings.appearance'], d=['components.ext-settings.appearance.*'], prio=2),
        R('9.07', 'Notifications tab (web push, desktop native, app notification controls)', 'components/settings/SettingsPanel.tsx NotificationsSection, AppNotificationsControls.tsx', 'DP',
          off=['components.settings.notifications.page'], d=['components.ext-settings.notifications.*', 'components.notifications.desktop.*'], prio=2),
        R('9.08', 'Server Profile tab (name, slug, avatar, description, public visibility)', 'components/settings/SettingsPanel.tsx ProfileSection, PublicVisibilitySection', 'DP',
          off=['components.settings.server.profile'], d=['components.ext-settings.server.*']),
        R('9.09', 'Server danger zone and its confirm modals (delete / leave server)', 'components/settings/SettingsPanel.tsx DangerZoneSection', 'DP',
          off=['screens.settings.server-danger-modal'], d=['components.auth-pages.desktop.settings.server-danger-*'], prio=2),
        R('9.10', 'Archived channels list (Unarchive)', 'components/settings/ArchivedChannelsSection.tsx', 'DP', d=['components.auth-pages.desktop.settings.archived-channels'], p=['components.auth-pages.mobile.settings.archived-channels'], prio=3,
          note='Flutter: ArchivedChannelsSection in Server settings (RaftArchivedChannelsSection); the React host patch now appends the channels once.'),
        R('9.11', 'Plan & Billing (free / trial, Pro, seats, checkout summary, confirm dialog, admin read-only, loading)', 'components/settings/SettingsPanel.tsx PlanSection', 'DP',
          off=['screens.settings.billing-portal'], d=['components.ext-settings.billing.*', '!*.mobile*'], p=['components.ext-settings.billing.mobile*']),
        R('9.12', 'Billing: downgrade warning card', 'components/settings/SettingsPanel.tsx DowngradeWarningCard', 'DP',
          d=['components.auth-pages.desktop.settings.downgrade-*'], p=['components.auth-pages.mobile.settings.downgrade-*'], prio=3),
        R('9.13', 'Administration (admins, system channels, invites, join links, agreement, onboarding, translation, analytics, member permissions)', 'components/settings/SettingsPanel.tsx AdministrationTabContent', 'DP',
          d=['components.ext-settings.administration.*', '!*.mobile.*'], p=['components.ext-settings.administration.mobile.*'],
          note='Phone: admins, join links, onboarding, pre-join agreement only.', p_state='partial'),
        R('9.14', 'Applications (installed, my apps, marketplace list / detail, installed detail, member read-only, empty)', 'components/settings/SettingsPanel.tsx IntegrationsSection', 'DP',
          d=['components.ext-settings.integrations.*', '!*.mobile*'], p=['components.ext-settings.integrations.mobile*']),
        R('9.15', 'Application editor (register app, redirect URLs, declared scopes, scope list)', 'components/settings/SettingsPanel.tsx ConnectedAppEditorSection, DeclaredScopesPicker', 'DP',
          d=['components.auth-pages.desktop.settings.app-editor'], p=['components.auth-pages.mobile.settings.app-editor'], prio=3,
          note='Flutter shows a generic form dialog, not the Web rail + sections editor.'),
        R('9.16', 'MCP Servers tab', 'components/settings/SettingsPanel.tsx McpSettingsSection', 'DP', d=['components.ext-settings.mcp.*', '!*.mobile'], p=['components.ext-settings.mcp.mobile'], prio=3),
        R('9.17', 'AI Providers tab (connections list)', 'components/settings/ProviderConnectionsSettings.tsx', 'DP', d=['components.ext-settings.providers.*', '!*.mobile'], p=['components.ext-settings.providers.mobile'], prio=3),
        R('9.18', 'AI provider edit modal (gateway, preset, save failed)', 'components/settings/EditProviderConnectionModal.tsx', 'DP',
          d=['components.wp6.settings.provider-edit', 'components.wp6.settings.provider-edit-preset', 'components.wp6.settings.provider-edit-error'],
          p=['components.wp6.settings.provider-edit-mobile', 'components.wp6.settings.provider-edit-preset-mobile']),
        R('9.19', 'IM Bridges tab', 'components/settings/IMBridgesSettingsSection.tsx', 'DP', d=['components.ext-settings.im-bridges.*', '!*.mobile'], p=['components.ext-settings.im-bridges.mobile'], prio=3),
        R('9.20', 'Slack bridge wizard (connect, OAuth, channel pairs, preflight, enable, health, recovery, manage, disconnect, load failed)', 'components/settings/SlackBridgeSetupWizard.tsx', 'DP',
          d=['components.wp6.settings.bridge-*', '!*-mobile'], p=['components.wp6.settings.bridge-*-mobile'], note='Phone: connect, channel pairs, preflight, recovery only.', p_state='partial'),
        R('9.21', 'Labs tab', 'components/settings/SettingsPanel.tsx LabsSection', 'DP', d=['components.ext-settings.labs.*', '!*.mobile'], p=['components.ext-settings.labs.mobile'], prio=3),
        R('9.22', 'About tab (version, mobile app QR, workspace)', 'components/settings/SettingsPanel.tsx AboutSection, MobileDownloadQr.tsx', 'DP', d=['components.ext-settings.about.*', '!*.mobile'], p=['components.ext-settings.about.mobile'], prio=3),
        R('9.23', 'Release notes (current, retracted, older, loading, error, empty)', 'components/settings/ReleaseNotesPanel.tsx', 'DP', d=['components.ext-settings.release-notes.*'], p=['components.auth-pages.mobile.settings.release-notes*'], prio=3),
        R('9.24', 'Feedback (inbox, new, ticket, reply, close, errors)', 'components/settings/AboutFeedbackDialog.tsx, feedback/*', 'DP',
          d=['components.ext-settings.feedback.*'], p=['components.wp6.settings.feedback-*-mobile']),
    ]),
]

# ---------------------------------------------------------------- reachability audit (owner follow-up 2026-10-11)
# Evidence from the pinned raft-source (packages/web/src, packages/server/drizzle, packages/shared/src). Only
# conservative marks: `excl` when the source shows the page is dead / withdrawn / flag-gated default-off / host-bound,
# `verify` when reachability is unclear or the page may not apply to a native client.
FLAG_SEED = 'server/drizzle seeds the flag default_enabled=false'
MARKS = {
    '6.03': dict(excl=('obsolete', 'TaskFilterSegmentedControl.tsx has no importer under src/; only tests/raftUiSegmentedControls.behavior.test.tsx '
                       'and tests/raftUiIntegration.contract.test.ts import it. TasksPanel.tsx uses its own filter popovers (task.filter.*).')),
    '6.09': dict(excl=('obsolete', 'LegacyTaskPanel opens only for `task.isLegacy` rows (TasksPanel.tsx:972-976, MessageItem.tsx:4184); '
                       'shared/src/agentText/tasks.ts:77 labels them "[LEGACY - read-only]"; new tasks open their message thread.')),
    '2.21': dict(excl=('flag-off', 'workspaceGridAvailability.ts gates on flag chat_grid_layout_v0 (config named WORKSPACE_GRID_DEMO); '
                       'migration 0151 "Workspace grid layout preview gate; Botiverse allowlist first", default_enabled=false.')),
    '7.21': dict(excl=('flag-off', 'AgentMigrationSection.tsx returns null unless useAgentMigrationUiEnabled() (flag agent_migration_v0); '
                       'migration 0150 default_enabled=false, 0154 dark-launches it to the botiverse server only.')),
    '7.22': dict(excl=('flag-off', 'AgentDetailPanel.tsx:1842 renders AgentConnections only for an external agent with hostedRuntime.state "active"; '
                       'hosted runtime is flag antiproton_hosted_runtime ("Server-stage, default off", shared/src/featureFlags.ts:11; migration 0296 default false).')),
    '1.29': dict(excl=('flag-off', 'OAuth return page of AgentConnections (7.22): same hosted-runtime flag antiproton_hosted_runtime, default off.')),
    '3.29': dict(verify='External-identity cards come from provider-bridge senders; slack_bridge_v0 and external_projection_directory are seeded default false and fail closed (migration 0252), but messages from an already-enabled bridge would show them. Confirm the bridge is out of scope before dropping.'),
    '9.17': dict(verify='provider_connections_v0 (migration 0217) was seeded default false, "initially limited to slock-android and botiverse servers"; the tab is hidden without it. Later rollout rules are not in the source. Cases exist (ext-settings.providers.*).'),
    '9.18': dict(verify='Edit modal of the AI Providers tab: same flag provider_connections_v0 as 9.17. Cases exist (wp6.settings.provider-edit*).'),
    '9.19': dict(verify='slack_bridge_v0 "Whole Slack Bridge launch and rollback gate": seeded default false with no allow rules (migration 0252); the tab is hidden without it. Cases exist (ext-settings.im-bridges.*).'),
    '9.20': dict(verify='Wizard of the IM Bridges tab: same flag slack_bridge_v0 as 9.19. Cases exist (wp6.settings.bridge-*, about 22).'),
    '9.21': dict(verify='server_labs_ui_v0 "Web Server Settings Labs UI exposure gate" (migration 0192, default false); the tab is hidden without it. Cases exist (ext-settings.labs.*).'),
    '2.13': dict(excl=('host-only', 'Sidebar.tsx:3856 renders SidebarConversationFinder only when isElectronDesktopShell(); the comment says "web withdraws it (@artin 2026-09-11)".')),
    '7.26': dict(excl=('host-only', 'handoff/handoffSessions.ts:59 isHandoffAvailable() = isElectronDesktopShell() && bridge; Sidebar.tsx:2447 shows the menu item only then.')),
    '3.40': dict(excl=('duplicate', 'ChannelOverflowMenu.tsx:568 renders EditChannelDialog: it is the channel settings sheet already listed as 4.04 / 4.05 '
                       '(the channelsettings cases open it through the header gear).')),
    '5.12': dict(verify='ThreadsInbox.tsx gates Saved / Done views (:872-879), the channel filter (:665), sort and in-list search (:922) on activity_sidebar_inbox_v0; no server migration seeds that key, so it evaluates disabled unless an operator created it. Flutter already ships a Saved view.'),
    # verify: kept in the counts.
    '1.19': dict(excl=('browser-only', 'PublicServerPage.tsx is the anonymous signed-out preview served on the Web origin (App.tsx:971-1000); the Flutter app has no signed-out route besides sign-in, so there is no route or feature to match (product decision to confirm).')),
    '1.20': dict(excl=('browser-only', 'Join confirm / guest join of the anonymous public server page (see 1.19): no signed-out public preview exists in the Flutter app.')),
    '1.25': dict(excl=('browser-only', 'DeviceLoginPage.tsx (/login/device) is the browser page the CLI / computer opens to approve a device code; the native client never renders it and has no route for it.')),
    '1.26': dict(excl=('browser-only', 'AppLoginPage.tsx (/login/app) is the HarmonyOS web-login hand-off (pages/AppLoginPage.tsx:10); not a Flutter surface.')),
    '1.27': dict(excl=('browser-only', "HumanLoginSetupPage.tsx (/login-with-raft/setup) is the third-party 'Login with Raft' consent page opened in a browser; the Flutter app has no such route.")),
    '1.28': dict(excl=('browser-only', 'IntegrationInvitePage.tsx (/integration-invite) is a browser page for OAuth-app invites; the Flutter app has no route for it.')),
    '1.30': dict(excl=('browser-only', 'MobileDownloadChooserPage.tsx (/download) is the public browser page behind the mobile download QR; a native client cannot show it.')),
    '1.31': dict(excl=('browser-only', 'ChineseCommunityPage.tsx is a browser landing page linked from help menus and the invite page; the Flutter app has no route for it.')),
    '1.32': dict(excl=('browser-only', 'PwaInstallPrompt.tsx is the iOS Safari add-to-home-screen prompt; meaningless inside a native app.')),
    '1.34': dict(excl=('browser-only', 'AppUpdateGate.tsx is the Web stale-bundle gate (main.tsx); a native app updates through its store.')),
    '1.11': dict(excl=('browser-only', 'SocialAuthCallbackPage.tsx is the browser tab a Web OAuth redirect lands on (loading / error); the native client runs OAuth in the system browser and exchanges the code itself (RaftApp.completeOAuth), so no such page exists in the app.')),
    '9.04': dict(verify='UsageDataSettings ("Share usage data") is behind product_analytics_settings_v0, documented "Default off: hidden until the default and the privacy-policy section are confirmed" (serverFeatureFlags.ts:31-35).'),
    '9.13': dict(verify='The product-analytics switch inside Administration is behind product_analytics_settings_v0 (default off, hidden); the other eight sections are visible.'),
    '9.22': dict(verify='The mobile-app QR section is behind mobile_download_v0 (migration 0225, botiverse first).'),
}
for _row in [r for _, _, _rows in SECTIONS for r in _rows]:
    if _row.num in MARKS:
        _m = MARKS.pop(_row.num)
        _row.excl, _row.verify = _m.get('excl', _row.excl), _m.get('verify', _row.verify)
assert not MARKS, f'unknown rows in MARKS: {sorted(MARKS)}'


EXCLUDED = [
    ('pages/PaletteAuditPage.tsx (/palette-audit)', 'dev-only', 'App.tsx PaletteAuditRoute redirects to / unless import.meta.env.DEV'),
    ('pages/AccountBootstrapPreviewPage.tsx (/dev/account-bootstrap)', 'dev-only', 'App.tsx: Navigate to / unless import.meta.env.DEV'),
    ('pages/ServerSetupComputerRuntimePreviewPage.tsx (/dev/server-setup)', 'dev-only', 'App.tsx: Navigate to / unless import.meta.env.DEV'),
    ('components/dev/DraggableDevOverlay.tsx, App.tsx dev overlay', 'dev-only', 'raftdev tooling overlay'),
    ('components/workspace/WorkspaceGridDemo.tsx (/workspace-grid-demo)', 'superseded',
     'MainLayout.tsx route WORKSPACE_GRID_DEMO_ROUTE renders LegacyWorkspaceGridRedirect; the real workspace mode is 2.21'),
    ('components/window/ThreadWindowRoute.tsx (/thread-window)', 'obsolete',
     'App.tsx comment: in-app entry points removed 2026-09-10 by product call; route kept only for later re-exposure'),
    ('/inbox and /threads', 'superseded', 'MainLayout.tsx routes render LegacyThreadsRedirect to Activity'),
]

REASONS = ('obsolete', 'flag-off', 'host-only', 'browser-only', 'dev-only', 'duplicate', 'superseded')
PRIO_LABEL = {1: 'P1 daily path', 2: 'P2 common', 3: 'P3 rare / admin / edge'}


# ---------------------------------------------------------------- derived data
def all_rows():
    return [r for _, _, rows in SECTIONS for r in rows]


def suffix_free(case_id):
    return case_id.rsplit('.', 1)[0] if case_id.rsplit('.', 1)[-1] in ('brutal', 'elegant', 'elegant-dark') else case_id


def brutal_cases(manifest):
    """-> [(suffix-free id, viewport width)] of the default theme."""
    return [(suffix_free(c['id']), c['viewport']['width']) for c in manifest['cases'] if c['theme'] == 'brutal-light']


def matching(patterns, cases):
    """Cases matching any positive glob and no `!`-prefixed glob."""
    pos = [g for g in patterns if not g.startswith('!')]
    neg = [g[1:] for g in patterns if g.startswith('!')]
    return [(i, w) for i, w in cases
            if any(fnmatch.fnmatchcase(i, g) for g in pos) and not any(fnmatch.fnmatchcase(i, g) for g in neg)]


def ext_globs():
    return sorted({g for r in all_rows() for g in (*r.d, *r.p)})


def official_globs():
    return sorted({g for r in all_rows() for g in r.off})


def counts():
    out = {'rows': 0, 'all_rows': 0, 'excluded': {}, 'verify': 0}
    for plat in 'DP':
        out[plat] = {'applicable': 0, 'ok': 0, 'partial': 0, 'wip': 0, 'MISSING': 0}
    out['rows_missing'] = out['rows_partial_or_wip'] = out['rows_full'] = 0
    for r in all_rows():
        out['all_rows'] += 1
        if r.excl:
            out['excluded'][r.excl[0]] = out['excluded'].get(r.excl[0], 0) + 1
            continue
        out['rows'] += 1
        out['verify'] += bool(r.verify)
        states = [r.state(p) for p in 'DP' if p in r.ap]
        for plat in 'DP':
            s = r.state(plat)
            if s != 'n/a':
                out[plat]['applicable'] += 1
                out[plat][s] += 1
        if 'MISSING' in states:
            out['rows_missing'] += 1
        elif any(s in ('partial', 'wip') for s in states):
            out['rows_partial_or_wip'] += 1
        else:
            out['rows_full'] += 1
    return out


def excluded_rows():
    return [r for r in all_rows() if r.excl]


def verify_rows():
    return [r for r in all_rows() if r.verify and not r.excl]


def missing_rows():
    """Rows with a MISSING platform, most visible first (priority, then rows not flagged verify, then both platforms,
    then document order). Excluded rows are not ranked."""
    rows = [(i, r) for i, r in enumerate(all_rows()) if not r.excl and 'MISSING' in [r.state(p) for p in 'DP']]
    rows.sort(key=lambda ir: (ir[1].prio, bool(ir[1].verify), -sum(ir[1].state(p) == 'MISSING' for p in 'DP'), ir[0]))
    return [r for _, r in rows]


def code(items):
    return '<br>'.join(f'`{i}`' for i in items)


def render():
    c = counts()
    miss = missing_rows()
    L = []
    a = L.append
    a('# Web page inventory vs Flutter parity coverage')
    a('')
    a('Generated by `tool/parity-ext/inventory.py` from the rows in that file; edit the rows, not this document,')
    a('then run `python3 tool/parity-ext/inventory.py`. `tool/tests/test_parity_ext.py` fails when this file is stale or')
    a('when an extension id named here no longer exists. Web source: the pinned raft-source checkout,')
    a('`packages/web/src` (routes in `App.tsx` and `components/layout/MainLayout.tsx`, tabs in')
    a('`components/settings/settingsNavigation.ts`, agent tabs in `components/agent/AgentDetailPanel.tsx`).')
    a('')
    a('## Owner decision (2026-10-11)')
    a('')
    a('The main problem is missing pages. The default theme (brutal-light) must cover ALL pages; the other themes')
    a('(elegant-light, elegant-dark) get one or two cases per surface for a simple alignment check. The runner')
    a('implements the sampling (`tool/parity-ext/sampling.py`, docs/parity.md "Theme sampling"). This inventory is the')
    a('list of pages that default-theme coverage must reach.')
    a('')
    a('## How to read it')
    a('')
    a('- One row per user-facing page, panel, modal, drawer, sheet, popover or empty / error state family worth a screen.')
    a('  Dev-only routes are excluded (end of the document); pages the Web source shows to nobody are marked `excluded`.')
    a('- **D** = desktop (extension suite, 1280 wide, brutal-light). **P** = phone (390 wide): the official suite')
    a('  (`tool/parity`, 99 cases, phone only) or an extension case with a `.mobile` / 390 viewport.')
    a('- Cell values: `ok` a case exists; `partial` only some states or only inside other cases; `wip` being added on another')
    a('  branch; `MISSING` no case; `n/a` the surface does not exist on that platform; `excluded` dead / obsolete / not shown to')
    a('  normal users (reason and evidence in "Excluded pages"): it drops out of the counts and the ranking.')
    a('- Extension ids are shown without the theme suffix (`.brutal` = brutal-light; the other two themes only exist for')
    a('  the sampled surfaces) and may be globs. "Coverage" means a case exists, not that Flutter passes it.')
    a('- Priority of a missing page by user visibility: **P1** daily path (every session), **P2** common secondary or')
    a('  first-run, **P3** rare, admin-only, flag-gated or edge state.')
    a('')
    a('## Summary')
    a('')
    ex = c['excluded']
    ex_routes = {}
    for _, reason, _ in EXCLUDED:
        ex_routes[reason] = ex_routes.get(reason, 0) + 1
    a(f"- Pages (rows) in the inventory: **{c['all_rows']}** in {len(SECTIONS)} areas, of which **{sum(ex.values())}** are excluded as dead,")
    a(f"  obsolete or not shown to normal users (below), leaving **{c['rows']}** pages that count. {len(EXCLUDED)} dev-only / entry-less")
    a(f"  routes are excluded on top (end of the document). {c['verify']} counted pages are flagged \"verify\" (reachability unclear).")
    a(f"- Fully covered on every platform they exist on: **{c['rows_full']}**; partly covered (partial / wip): **{c['rows_partial_or_wip']}**;"
      f" with at least one MISSING platform: **{c['rows_missing']}**.")
    a('')
    a('| platform | pages that exist there | ok | partial | wip | MISSING |')
    a('| --- | --- | --- | --- | --- | --- |')
    a(f"| Desktop (D) | {c['D']['applicable']} | {c['D']['ok']} | {c['D']['partial']} | {c['D']['wip']} | {c['D']['MISSING']} |")
    a(f"| Phone (P) | {c['P']['applicable']} | {c['P']['ok']} | {c['P']['partial']} | {c['P']['wip']} | {c['P']['MISSING']} |")
    a('')
    a('Excluded pages by reason (rows / extra routes):')
    a('')
    a('| reason | rows | routes | meaning |')
    a('| --- | --- | --- | --- |')
    meaning = {
        'obsolete': 'no entry point, or reachable only for legacy data, or no production importer',
        'flag-off': 'exists only behind a server feature flag seeded default-off (staged / allowlist / preview)',
        'host-only': 'needs the Electron desktop shell bridge; not shown in a browser or a native client',
        'browser-only': 'a Web page that only exists in the browser; the Flutter app has no route or feature for it',
        'dev-only': 'development tooling, redirected away in production',
        'duplicate': 'the same screen as another row',
        'superseded': 'replaced by a newer page; only a redirect remains',
    }
    for reason in REASONS:
        a(f"| {reason} | {ex.get(reason, 0)} | {ex_routes.get(reason, 0)} | {meaning[reason]} |")
    a('')
    a('Findings:')
    a('')
    a('- The official suite covers phone only, so every desktop page depends on the extension suite; the extension')
    a('  suite is concentrated on Settings, Auth, Thread and Shell components and has almost no composed desktop screens.')
    a(f"- {c['D']['MISSING']} desktop and {c['P']['MISSING']} phone page-platforms have no case.")
    a('- Agent detail: `AgentDetailPanel` has seven tabs (profile, activity, chat, reminders, workspace, apps, MCP). The')
    a('  base branch already has desktop cases for six of them (`components.members-ext.agent.*`, including `mcp*`). Chat has')
    a('  no case on either platform and MCP has none on phone. Desktop agent-detail work is in progress on')
    a('  `cindy/alignment-audit`; this inventory does not add cases for it.')
    a('')
    a('## Prioritized missing pages')
    a('')
    a('Ordered by priority, then pages not flagged "verify" first, then missing on both platforms, then area order. "Where" names the platform(s) without a case; "verify" marks pages whose reachability is unclear (section "Verify").')
    a('')
    a('| rank | # | page | where | priority |')
    a('| --- | --- | --- | --- | --- |')
    for n, r in enumerate(miss, 1):
        where = '+'.join(p for p in 'DP' if r.state(p) == 'MISSING')
        a(f"| {n} | {r.num} | {r.name}{' (verify)' if r.verify else ''} | {where} | {PRIO_LABEL[r.prio]} |")
    a('')
    for title, intro, rows in SECTIONS:
        a(f'## {title}')
        a('')
        a(f'Web: {intro}.')
        a('')
        a('| # | page / state | Web component | D | P | official (phone) ids | extension ids (brutal-light) | note |')
        a('| --- | --- | --- | --- | --- | --- | --- | --- |')
        for r in rows:
            ext = []
            if r.d:
                ext.append('D: ' + code(r.d))
            if r.p:
                ext.append('P: ' + code(r.p))
            note = r.note
            if r.excl:
                note = (note + ' ' if note else '') + f'[excluded: {r.excl[0]}]'
            if r.verify and not r.excl:
                note = (note + ' ' if note else '') + '[verify]'
            if r.state('D') == 'MISSING' or r.state('P') == 'MISSING':
                note = (note + ' ' if note else '') + f'[{PRIO_LABEL[r.prio].split()[0]}]'
            a(f"| {r.num} | {r.name} | `{r.web}` | {r.state('D')} | {r.state('P')} | {code(r.off) or ''} | {'<br>'.join(ext)} | {note} |")
        a('')
    a('## Excluded pages')
    a('')
    a('Reachability evidence comes from the pinned Web source only (the checkout is a single release commit, so there is no')
    a('git history). Rollout state of a flag is operational data, not in the source: if a flagged feature has since been')
    a('enabled for everyone, delete its `excl=` in `inventory.py` and it counts again. Every excluded page keeps its row and')
    a('number above.')
    a('')
    a('| # | page | reason | evidence |')
    a('| --- | --- | --- | --- |')
    for r in excluded_rows():
        a(f"| {r.num} | {r.name} | {r.excl[0]} | {r.excl[1]} |")
    a('')
    a('Excluded pages that still have cases (cases that can be dropped from the default run if the exclusion holds):')
    a('')
    for r in excluded_rows():
        ids = [i for i in (*r.off, *r.d, *r.p) if not i.startswith('!')]
        if ids:
            a(f"- {r.num} {r.name}: " + ', '.join(f'`{i}`' for i in ids))
    a('')
    a('## Excluded routes')
    a('')
    a('| route / file | reason | evidence |')
    a('| --- | --- | --- |')
    for name, reason, why in EXCLUDED:
        a(f'| `{name}` | {reason} | {why} |')
    a('')
    a('## Verify (kept in the counts)')
    a('')
    a('Pages whose reachability is unclear or that may not apply to a native client. They stay counted; confirm with the owner')
    a('before spending case effort.')
    a('')
    a('| # | page | what to verify |')
    a('| --- | --- | --- |')
    for r in verify_rows():
        a(f"| {r.num} | {r.name} | {r.verify} |")
    a('')
    a('## Maintaining this document')
    a('')
    a('1. Add or change cases through the builder pattern (docs/parity-ext-quickstart.md).')
    a('2. Update the matching row(s) in `tool/parity-ext/inventory.py` (`d=` / `p=` extension ids, `off=` official ids,')
    a('   `*_state=` for partial / wip) and run `python3 tool/parity-ext/inventory.py`.')
    a('3. `python3 tool/parity-ext/inventory.py --check` (also run by the unit tests) fails on stale output and on ids that')
    a('   match no case.')
    a('')
    return '\n'.join(L).replace('\n\n\n', '\n\n')


def official_ids():
    shared = RAFT_SOURCE / 'packages/visual-testing/shared/sharedCases.json'
    if not shared.is_file():
        return None
    return [c['id'] for c in json.loads(shared.read_text())['cases']]


def build_cases():
    sys.path.insert(0, str(HERE))
    import builders
    with tempfile.TemporaryDirectory() as tmp:
        manifest = json.loads(builders.build_manifest(pathlib.Path(tmp)).read_text())
    return brutal_cases(manifest)


def problems(cases=None, official=None):
    """-> list of human readable problems (empty = consistent)."""
    cases = build_cases() if cases is None else cases
    out = []
    for r in all_rows():
        for platform, patterns in (('D', r.d), ('P', r.p)):
            if patterns and platform not in r.ap:
                out.append(f'{r.num}: extension ids given for {platform} but the row is {r.ap}')
            for g in patterns:
                if g.startswith('!'):
                    continue
                hit = matching([g, *[x for x in patterns if x.startswith('!')]], cases)
                if not hit:
                    out.append(f'{r.num}: extension id matches no brutal-light case: {g}')
                elif platform == 'D' and any(w == 390 for _, w in hit):
                    out.append(f'{r.num}: desktop glob {g} matches a 390 wide (phone) case')
                elif platform == 'P' and any(w != 390 for _, w in hit):
                    out.append(f'{r.num}: phone glob {g} matches a non-390 case')
    if official is not None:
        for r in all_rows():
            for g in r.off:
                if not fnmatch.filter(official, g):
                    out.append(f'{r.num}: official id matches no sharedCases.json case: {g}')
    return out


def main():
    check = '--check' in sys.argv
    text = render()
    bad = problems(official=official_ids())
    if check:
        if not DOC.is_file() or DOC.read_text() != text:
            bad.append(f'{DOC.relative_to(ROOT)} is stale: run python3 tool/parity-ext/inventory.py')
        if bad:
            sys.exit('\n'.join(bad))
        print('inventory consistent')
        return
    if bad:
        sys.exit('\n'.join(bad))
    DOC.write_text(text)
    c = counts()
    print(f"wrote {DOC.relative_to(ROOT)}: {c['rows']} pages, desktop {c['D']}, phone {c['P']}")


if __name__ == '__main__':
    main()
