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

/// Shows the handle (① ② ③ …) of the entity a card stands for, small in its
/// corner, and makes a tap on the card "point" at it: the next thing said
/// with "这个" means this card. The tap still reaches the card; this only
/// listens.
///
/// [focusId] is the id the card has as an `AgentFocusable` (`layer#3`);
/// cards that are not on the front screen, or stand for no entity, are
/// left as they are.
class AgentHandleTag extends StatelessWidget {
  const AgentHandleTag({
    super.key,
    required this.focusId,
    required this.child,
    this.showHandle = true,
  });

  final String focusId;
  final Widget child;

  /// False for a card that already wears its number (the home cards show
  /// their rank, which is the handle): it still points when tapped.
  final bool showHandle;

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
      showHandle: showHandle,
      child: child,
    );
  }
}

class _Tagged extends StatefulWidget {
  const _Tagged({
    required this.entry,
    required this.layerId,
    required this.pointer,
    required this.showHandle,
    required this.child,
  });
  final bool showHandle;
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
    final t = RaftAgentTheme.of(context);
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
          return Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              child!,
              if (widget.showHandle)
                Positioned(
                  top: 4,
                  right: 6,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Container(
                        key: ValueKey('agent-handle-${widget.entry.index}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: pointed ? t.markHighlight : t.chip,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: t.line, width: .8),
                        ),
                        child: Text(
                          widget.entry.handle,
                          style: t
                              .body(
                                16,
                                color: t.foreground,
                                weight: FontWeight.w800,
                              )
                              .copyWith(height: 1.1),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        child: widget.child,
      ),
    );
  }
}
