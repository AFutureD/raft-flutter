import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'text_selection_toolbar.dart';

/// [SelectionArea] whose touch selection ends with the next touch elsewhere.
///
/// Flutter keeps a touch selection (highlight, handles) until the same text is
/// tapped again: only Web unfocuses a [SelectableRegion] on an outside tap. The
/// message timeline hides the platform toolbar, so a phone user has no Copy /
/// Clear button either, and the selection stays on screen like a stuck desktop
/// hover. A touch or stylus press outside every selectable region clears it.
/// The shared [SelectableRegion] tap group keeps taps on the selection handles
/// and on other selectable regions "inside". Mouse and trackpad keep Flutter's
/// desktop behaviour (the selection stays until replaced).
class RaftSelectionArea extends StatefulWidget {
  const RaftSelectionArea({
    super.key,
    required this.child,
    this.contextMenuBuilder = _platformToolbar,
  });
  final Widget child;
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  static Widget _platformToolbar(
    BuildContext context,
    SelectableRegionState state,
  ) => RaftTextSelectionToolbar.selectableRegion(context, state);

  /// The platform Copy / Select all toolbar for a touch selection, nothing
  /// for a mouse or trackpad. For areas whose desktop right-click belongs to
  /// the host (a message row's action menu) but whose phone selection still
  /// needs its Copy / Select all toolbar: the host hides the platform
  /// toolbar everywhere, so without this a long-press selection on a phone
  /// has no way to copy.
  static Widget touchToolbarOnly(
    BuildContext context,
    SelectableRegionState state,
  ) {
    // The density scope falls back to the platform (phones are touch).
    return RaftDensityScope.of(context) == RaftDensity.touch
        ? _platformToolbar(context, state)
        : const SizedBox.shrink();
  }

  @override
  State<RaftSelectionArea> createState() => _RaftSelectionAreaState();
}

class _RaftSelectionAreaState extends State<RaftSelectionArea> {
  /// Context inside the area: its [SelectableRegionState] is the nearest
  /// ancestor state (no per-row GlobalKey).
  BuildContext? inside;

  void outsidePress(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      return;
    }
    final inner = inside;
    if (inner == null || !inner.mounted) return;
    inner.findAncestorStateOfType<SelectableRegionState>()?.clearSelection();
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: SelectableRegion,
    onTapOutside: outsidePress,
    // ignore: raft_lints/avoid_bare_selection_area -- this is the wrapper
    child: SelectionArea(
      contextMenuBuilder: widget.contextMenuBuilder,
      child: Builder(
        builder: (context) {
          inside = context;
          return widget.child;
        },
      ),
    ),
  );
}
