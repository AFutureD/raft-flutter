import 'package:flutter/material.dart';

import 'raft_ui.dart';

/// API-free preview of the shared target picker, including a large lazy list.
Widget incomingShareTargetsPreview() => const _Targets();

class _Targets extends StatefulWidget {
  const _Targets();
  @override
  State<_Targets> createState() => _TargetsState();
}

class _TargetsState extends State<_Targets> {
  final search = TextEditingController(), focus = FocusNode();
  int? selected;
  @override
  void dispose() {
    search.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RaftForwardPage(
    child: Column(
      children: [
        RaftMobilePageHeader(
          title: const Text('Select destinations'),
          onBack: () {},
        ),
        Expanded(
          child: RaftForwardTargetsBody(
            search: RaftForwardSearchInput(
              controller: search,
              focusNode: focus,
              placeholder: 'Search targets',
              onChanged: (_) => setState(() {}),
            ),
            label: selected == null
                ? 'Conversations'
                : '#channel-$selected selected',
            itemCount: search.text.isEmpty ? 10000 : 5,
            itemBuilder: (_, index) => RaftForwardTargetRow(
              icon: raftForwardTargetIcon(
                name: 'channel-$index',
                type: 'channel',
              ),
              label: '#channel-$index',
              selected: selected == index,
              checkbox: true,
              onTap: () =>
                  setState(() => selected = selected == index ? null : index),
            ),
          ),
        ),
        RaftPanel(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              RaftForwardTextAction(
                label: 'Clear',
                onPressed: selected == null
                    ? null
                    : () => setState(() => selected = null),
              ),
              RaftButton(
                label: 'Continue',
                onPressed: selected == null ? null : () {},
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
