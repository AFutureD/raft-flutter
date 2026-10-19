import 'package:flutter/material.dart';

import 'raft/switch.dart';

enum RaftSwitchSize { sm, md }

/// Source visual dimensions of raft-ui 0.7.1 `Switch`: one 50x30 size ([RaftSwitchSize] is kept for call sites
/// and no longer changes the geometry).
@immutable
class RaftSwitchRecipe {
  const RaftSwitchRecipe({this.size = RaftSwitchSize.md});
  final RaftSwitchSize size;
  Size get visualSize =>
      const Size(RaftSwitchMetrics.width, RaftSwitchMetrics.height);
  double get thumbSize => RaftSwitchMetrics.thumb;
  double get thumbInset => RaftSwitchMetrics.padding;
  double get travel => RaftSwitchMetrics.travel;
}

/// Controlled source Switch. A disabled control never invokes [onChanged].
class RaftSwitch extends StatelessWidget {
  const RaftSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.size = RaftSwitchSize.sm,
    this.enabled = true,
    this.semanticLabel,
    this.semanticDescription,
    this.minimumTargetSize,
  });
  final bool value, enabled;
  final ValueChanged<bool>? onChanged;

  /// Accepted for call sites; raft-ui 0.7.1 has the single 50x30 switch.
  final RaftSwitchSize size;
  final String? semanticLabel, semanticDescription;
  final double? minimumTargetSize;

  @override
  Widget build(BuildContext context) => RaftSwitchControl(
    value: value,
    onChanged: onChanged,
    enabled: enabled,
    semanticLabel: semanticLabel,
    semanticDescription: semanticDescription,
    minimumTargetSize: minimumTargetSize,
  );
}
