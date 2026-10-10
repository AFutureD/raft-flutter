import 'package:flutter/material.dart';

import 'previews.dart';
import 'raft_ui.dart';

@RaftPreviews('Mobile channel settings page', size: Size(390, 844))
Widget channelSettingsPagePreview() => const _ChannelPagesPreview();

@RaftPreviews('Mobile channel members page', size: Size(390, 844))
Widget channelMembersPagePreview() => const _ChannelPagesPreview(members: true);

@RaftPreviews('Mobile channel members loading', size: Size(390, 844))
Widget channelMembersLoadingPreview() =>
    const _ChannelPagesPreview(members: true, loading: true);

@RaftPreviews('Mobile channel settings error', size: Size(390, 844))
Widget channelSettingsErrorPreview() =>
    const _ChannelPagesPreview(error: 'Unable to refresh settings. Try again.');

class _ChannelPagesPreview extends StatefulWidget {
  const _ChannelPagesPreview({
    this.members = false,
    this.loading = false,
    this.error,
  });
  final bool members, loading;
  final String? error;
  @override
  State<_ChannelPagesPreview> createState() => _ChannelPagesPreviewState();
}

class _ChannelPagesPreviewState extends State<_ChannelPagesPreview> {
  late bool members = widget.members;
  bool adding = false, pinned = false;
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => members
      ? RaftChannelMembersModal(
          page: true,
          channelName: 'general',
          search: search,
          loading: widget.loading,
          error: widget.error,
          onClose: () => setState(() => members = false),
          addView: adding,
          onAdd: () => setState(() => adding = true),
          onBack: () => setState(() => adding = false),
          hasCandidates: true,
          humans: const [
            RaftMemberRowData(
              label: 'Alice',
              avatar: RaftAvatar(name: 'Alice'),
            ),
          ],
          isChecked: (_) => false,
          onToggle: (_) {},
          onConfirm: () => setState(() => adding = false),
        )
      : RaftChannelSettingsSheet(
          page: true,
          channelName: 'general',
          channelDescription: 'A channel for everyone in the workspace.',
          error: widget.error,
          onClose: () {},
          onMembers: () => setState(() => members = true),
          onEdit: () => showDialog<void>(
            context: context,
            builder: (_) => RaftFormDialog(
              title: 'Edit channel',
              fields: const [
                RaftFormField(
                  'name',
                  'Name',
                  initial: 'general',
                  required: true,
                ),
              ],
              onSubmit: (_) async {},
            ),
          ),
          sections: [
            RaftSheetSection('Preferences', [
              RaftSheetSwitchRow(
                title: 'Pin channel',
                description:
                    'Keep this channel pinned to the top of your sidebar.',
                value: pinned,
                onChanged: (value) => setState(() => pinned = value),
              ),
            ]),
          ],
        );
}
