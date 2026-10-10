import 'package:flutter/material.dart';

import 'previews.dart';
import 'raft_ui.dart';

@RaftPreviews('Lazy task sections', size: Size(390, 720))
Widget taskSectionPreview() => const _TaskSections();

class _TaskSections extends StatefulWidget {
  const _TaskSections();
  @override
  State<_TaskSections> createState() => _TaskSectionsState();
}

class _TaskSectionsState extends State<_TaskSections> {
  final collapsed = <String>{};
  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverMainAxisGroup(
          slivers: [
            for (final status in raftTaskStatuses) ...[
              RaftSliverTaskSection(
                status: status,
                count: status == 'closed' ? 0 : 120,
                collapsed: collapsed.contains(status),
                emptyLabel: 'No closed tasks',
                onToggle: () => setState(() {
                  if (!collapsed.remove(status)) collapsed.add(status);
                }),
                itemBuilder: (_, i) => SourceTaskRowExtent(
                  key: ValueKey('$status-$i'),
                  child: RaftTaskCard(
                    title: 'Review task ${i + 1}',
                    number: '${i + 1}',
                    status: status,
                    onTap: () {},
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ],
        ),
      ),
    ],
  );
}
