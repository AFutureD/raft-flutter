// Web `member/InviteHumanDialog.tsx`: the "Invite Human" DialogCard (`max-w-lg`)
// with the By email / By link segmented control, one row per invitee (email
// Input + optional role Select + remove), "Add another", the join-link field
// with its limits, and Cancel / Send invites. Presentation only: the app owns
// requests, billing gates and navigation.
import 'package:flutter/material.dart';

import 'banner.dart';
import 'dialog_card.dart';
import 'icons.dart';
import 'localization.dart';
import 'recipes/button_variants.g.dart';
import 'select_field.dart';
import 'theme.dart';

/// One invite row: the typed [email] and its [role] (`member` or `guest`).
class RaftInvitee {
  RaftInvitee({this.email = '', this.role = 'member'}) : id = _next++;
  static int _next = 0;
  final int id;
  String email, role;
}

/// State of the join link the By link tab shows.
class RaftInviteLink {
  const RaftInviteLink({
    this.loading = false,
    this.url,
    this.copied = false,
    this.hasLink = false,
    this.maxUses,
    this.expiresOn,
    this.usedLabel,
  });
  final bool loading, copied, hasLink;
  final String? url, usedLabel, expiresOn;
  final int? maxUses;
}

class RaftInviteHumanDialog extends StatefulWidget {
  const RaftInviteHumanDialog({
    super.key,
    required this.onClose,
    required this.onSend,
    this.canOfferGuest = false,
    this.link = const RaftInviteLink(),
    this.onCopyLink,
    this.onApplyLink,
    this.onRevokeLink,
    this.initialTab = 'email',
    this.seatLimitMessage,
    this.onViewBilling,
  });
  final VoidCallback onClose;
  final bool canOfferGuest;

  /// Sends `(email, role)` for every filled row; throws to show the error.
  final Future<void> Function(List<(String, String)> invites) onSend;
  final RaftInviteLink link;
  final VoidCallback? onCopyLink, onRevokeLink;

  /// Apply: `(maxUsesChoice, expiryChoice)` as the Select values.
  final void Function(String maxUses, String expiry)? onApplyLink;
  final String initialTab;
  final String? seatLimitMessage;
  final VoidCallback? onViewBilling;
  @override
  State<RaftInviteHumanDialog> createState() => _RaftInviteHumanDialogState();
}

class _RaftInviteHumanDialogState extends State<RaftInviteHumanDialog> {
  late String tab = widget.initialTab;
  final invitees = <RaftInvitee>[RaftInvitee()];
  final controllers = <int, TextEditingController>{};
  bool sending = false;
  String? error;
  String maxUses = 'unlimited', expiry = 'never';
  final _linkController = TextEditingController();

  TextEditingController controllerFor(RaftInvitee i) =>
      controllers.putIfAbsent(i.id, () => TextEditingController(text: i.email));

  @override
  void dispose() {
    _linkController.dispose();
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> send() async {
    final targets = [
      for (final i in invitees)
        if (i.email.trim().isNotEmpty) (i.email.trim(), i.role),
    ];
    if (targets.isEmpty) {
      setState(
        () => error = raftText(
          context,
          'Enter at least one email, or copy the invite link above.',
        ),
      );
      return;
    }
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.onSend(targets);
    } catch (e) {
      if (mounted) {
        setState(() {
          sending = false;
          error = e is StateError ? e.message : '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final seatReached = widget.seatLimitMessage != null && tab == 'email';
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: RaftDialogCard(
          key: const ValueKey('invite-dialog'),
          title: 'Invite Human',
          maxWidth: 512,
          onClose: widget.onClose,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // `space-y-4`
              if (error != null && !seatReached) ...[
                RaftBanner(
                  description: error!,
                  descriptionWeight: FontWeight.w700,
                ),
                const SizedBox(height: 16),
              ],
              if (seatReached) ...[
                RaftBanner(
                  description: widget.seatLimitMessage!,
                  descriptionWeight: FontWeight.w700,
                ),
                const SizedBox(height: 16),
              ],
              RaftRecipeSegmentedControl<String>(
                value: tab,
                label: raftText(context, 'Invite method'),
                items: const [
                  ('email', null, 'By email'),
                  ('link', null, 'By link'),
                ],
                onChanged: (v) => setState(() => tab = v),
              ),
              const SizedBox(height: 16),
              if (tab == 'email') _email(context, t) else _link(context, t),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  RaftRecipeButton(
                    label: raftText(context, 'Cancel'),
                    variant: RaftButtonRecipeVariant.outline,
                    size: RaftButtonRecipeSize.sm,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    textStep: RaftTextSteps.sm,
                    onPressed: widget.onClose,
                  ),
                  if (tab == 'email') ...[
                    const SizedBox(width: 12),
                    RaftRecipeButton(
                      key: const ValueKey('invite-send'),
                      label: sending
                          ? raftText(context, 'Sending…')
                          : raftText(context, 'Send invites'),
                      glyph: RaftGlyph.mail,
                      glyphSize: 14,
                      variant: RaftButtonRecipeVariant.accent,
                      size: RaftButtonRecipeSize.sm,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      textStep: RaftTextSteps.sm,
                      gap: 6,
                      disabled: sending || seatReached,
                      onPressed: send,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `<label className="mb-1 block text-sm font-bold text-foreground-strong
  /// uppercase tracking-wide">` (a bare label: no Field gap).
  Widget _fieldLabel(BuildContext context, RaftTokens t, String text) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          raftText(context, text).toUpperCase(),
          style: raftCssTextStyle(
            family: t.headingFont,
            step: RaftTextSteps.sm,
            weight: FontWeight.w700,
            color: t.colors['foreground-strong'],
            trackingEm: .025,
          ),
        ),
      );

  Widget _email(BuildContext context, RaftTokens t) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _fieldLabel(context, t, 'Invite by Email'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, invitee) in invitees.indexed) ...[
            if (index > 0) const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: RaftDialogTextInput(
                    fieldKey: ValueKey('invite-email-$index'),
                    controller: controllerFor(invitee)
                      ..addListener(
                        () => invitee.email = controllerFor(invitee).text,
                      ),
                    placeholder: 'name@company.com',
                  ),
                ),
                if (widget.canOfferGuest) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 112,
                    child: RaftSelectField<String>(
                      value: invitee.role,
                    height: 36, // chrome="field": the Input's box
                      label: raftText(context, 'Role'),
                      items: [
                        DropdownMenuItem(
                          value: 'member',
                          child: Text(raftText(context, 'Member')),
                        ),
                        DropdownMenuItem(
                          value: 'guest',
                          child: Text(raftText(context, 'Guest')),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => invitee.role = v ?? 'member'),
                    ),
                  ),
                ],
                if (invitees.length > 1) ...[
                  const SizedBox(width: 8),
                  RaftRecipeButton(
                    glyph: RaftGlyph.trash2,
                    glyphSize: 14,
                    variant: RaftButtonRecipeVariant.danger,
                    size: RaftButtonRecipeSize.iconXs,
                    tooltip: raftFormat(context, 'Remove invitee {index}', {
                      'index': index + 1,
                    }),
                    onPressed: () => setState(() => invitees.remove(invitee)),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: RaftRecipeButton(
              key: const ValueKey('invite-add'),
              label: raftText(context, 'Add another'),
              glyph: RaftGlyph.plus,
              glyphSize: 14,
              variant: RaftButtonRecipeVariant.ghost,
              size: RaftButtonRecipeSize.sm,
              onPressed: () => setState(() => invitees.add(RaftInvitee())),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _link(BuildContext context, RaftTokens t) {
    final link = widget.link;
    final urlText = link.loading
        ? raftText(context, 'Preparing invite link…')
        : link.url ?? raftText(context, 'Invite link unavailable');
    _linkController.text = urlText;
    DropdownMenuItem<String> item(String v, String label) =>
        DropdownMenuItem(value: v, child: Text(raftText(context, label)));
    final muted = t.colors['foreground-muted'];
    Widget labelText(String text) => Text(
      raftText(context, text),
      style: TextStyle(
        fontFamily: t.headingFont,
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w700,
        color: muted,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(context, t, 'Invite Link'),
        Row(
          children: [
            Expanded(
              child: RaftDialogTextInput(
                fieldKey: const ValueKey('invite-link-field'),
                controller: _linkController,
                readOnly: true,
                mono: true,
              ),
            ),
            const SizedBox(width: 8),
            RaftRecipeButton(
              key: const ValueKey('invite-link-copy'),
              glyph: link.copied ? RaftGlyph.check : RaftGlyph.copy,
              glyphSize: 14,
              size: RaftButtonRecipeSize.iconMd,
              tooltip: raftText(context, 'Copy invite link'),
              disabled: link.url == null || link.loading,
              onPressed: widget.onCopyLink,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                labelText('Uses'),
                const SizedBox(width: 6),
                SizedBox(
                  width: 128,
                  child: RaftSelectField<String>(
                    value: maxUses,
                    label: raftText(context, 'Uses'),
                    items: [
                      item('unlimited', 'Unlimited'),
                      item('1', '1 use'),
                      item('5', '5 uses'),
                      item('10', '10 uses'),
                      item('25', '25 uses'),
                      item('100', '100 uses'),
                    ],
                    onChanged: (v) => setState(() => maxUses = v ?? maxUses),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                labelText('Expires'),
                const SizedBox(width: 6),
                SizedBox(
                  width: 128,
                  child: RaftSelectField<String>(
                    value: expiry,
                    label: raftText(context, 'Expires'),
                    items: [
                      item('never', 'Never'),
                      item('1h', '1 hour'),
                      item('1d', '1 day'),
                      item('7d', '7 days'),
                      item('30d', '30 days'),
                    ],
                    onChanged: (v) => setState(() => expiry = v ?? expiry),
                  ),
                ),
              ],
            ),
            RaftRecipeButton(
              key: const ValueKey('invite-link-apply'),
              label: raftText(context, 'Update link'),
              size: RaftButtonRecipeSize.sm,
              disabled: link.loading,
              onPressed: widget.onApplyLink == null
                  ? null
                  : () => widget.onApplyLink!(maxUses, expiry),
            ),
            if (link.hasLink)
              GestureDetector(
                key: const ValueKey('invite-link-revoke'),
                onTap: widget.onRevokeLink,
                child: Text(
                  raftText(context, 'Revoke link'),
                  style: TextStyle(
                    fontFamily: t.headingFont,
                    fontSize: 12,
                    height: 16 / 12,
                    fontWeight: FontWeight.w700,
                    color: t.brutal
                        ? t.colors['brutal-pink']
                        : t.colors['accent-strong'],
                  ),
                ),
              ),
          ],
        ),
        if (link.hasLink) ...[
          const SizedBox(height: 4),
          Text(
            raftText(
              context,
              'Updating replaces the current link — the old one stops working.',
            ),
            style: TextStyle(
              fontFamily: t.headingFont,
              fontSize: 11,
              height: 16.5 / 11,
              color: muted?.withValues(alpha: .8),
            ),
          ),
        ],
        if (link.usedLabel != null || link.expiresOn != null) ...[
          const SizedBox(height: 4),
          Text(
            [?link.usedLabel, ?link.expiresOn].join(' · '),
            key: const ValueKey('invite-link-status'),
            style: TextStyle(
              fontFamily: t.headingFont,
              fontSize: 12,
              height: 16 / 12,
              color: muted,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Row(
          children: [
            RaftIcon(RaftGlyph.link2, size: 12, color: muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                raftText(
                  context,
                  widget.seatLimitMessage != null
                      ? 'This link will show a seat-limit message until you add a human seat.'
                      : 'Send this link to your teammates to join the server.',
                ),
                style: TextStyle(
                  fontFamily: t.headingFont,
                  fontSize: 12,
                  height: 16 / 12,
                  color: muted,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
