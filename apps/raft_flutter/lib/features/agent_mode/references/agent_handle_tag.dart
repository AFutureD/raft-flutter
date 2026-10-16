import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;

import 'agent_reference_table.dart';

/// What the cards of the front screen need to show their handle and to be
/// pointed at: the table and the pointer. Placed once above the layers.
class AgentReferenceScope extends InheritedWidget {
  const AgentReferenceScope({
    super.key,
    required this.table,
    required this.pointer,
    required super.child,
  });

  final AgentReferenceTable table;
  final AgentPointer pointer;

  static AgentReferenceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentReferenceScope>();

  @override
  bool updateShouldNotify(AgentReferenceScope old) =>
      !identical(old.table, table) || !identical(old.pointer, pointer);
}

/// Makes a tap on the card "point" at the entity it stands for: the next
/// thing said with "这个" means this card. The tap still reaches the card;
/// this only listens. The number the card wears on its bar is the handle
/// (① ② ③ …), so there is no badge to draw; a pointed card gets a yellow
/// outline.
///
/// [focusId] is the id the card has as an `AgentFocusable` (`layer#3`);
/// cards that are not on the front screen, or stand for no entity, are
/// left as they are.
class AgentHandleTag extends StatelessWidget {
  const AgentHandleTag({super.key, required this.focusId, required this.child});

  final String focusId;
  final Widget child;

  /// A tap moves less than this and ends within [tapTime].
  static const slop = 18.0;
  static const tapTime = Duration(milliseconds: 500);

  @override
  Widget build(BuildContext context) {
    final scope = AgentReferenceScope.maybeOf(context);
    final entry = scope?.table.byFocusId(focusId);
    if (scope == null || entry == null) return child;
    return _Tagged(
      entry: entry,
      layerId: scope.table.layerId,
      pointer: scope.pointer,
      child: child,
    );
  }
}

class _Tagged extends StatefulWidget {
  const _Tagged({
    required this.entry,
    required this.layerId,
    required this.pointer,
    required this.child,
  });
  final AgentEntityRef entry;
  final String layerId;
  final AgentPointer pointer;
  final Widget child;

  @override
  State<_Tagged> createState() => _TaggedState();
}

class _TaggedState extends State<_Tagged> {
  Offset? _down;
  Duration? _downAt;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _down = e.position;
        _downAt = e.timeStamp;
      },
      onPointerUp: (e) {
        final down = _down, at = _downAt;
        _down = _downAt = null;
        if (down == null || at == null) return;
        if ((e.position - down).distance <= AgentHandleTag.slop &&
            e.timeStamp - at <= AgentHandleTag.tapTime) {
          widget.pointer.point(widget.layerId, widget.entry);
        }
      },
      onPointerCancel: (_) => _down = _downAt = null,
      child: ListenableBuilder(
        listenable: widget.pointer,
        builder: (context, child) {
          final pointed =
              widget.pointer.entity == widget.entry &&
              widget.pointer.layerId == widget.layerId;
          if (!pointed) return child!;
          return DecoratedBox(
            key: ValueKey('agent-pointed-${widget.entry.index}'),
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(hf.sp(18)),
              border: Border.all(color: HfColors.sticker, width: hf.sp(4)),
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
