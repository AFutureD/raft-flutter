import 'package:raft_agent_ui/raft_agent_ui.dart' show mergeNodeProps;

import 'agent_surface.dart';

/// A surface that is being composed piece by piece.
///
/// The shape follows A2UI on purpose, so genui could replace this later:
/// `begin_surface` is `beginRendering` plus the first `surfaceUpdate` (the
/// layout skeleton), `add_component` and `update_component` are
/// `surfaceUpdate`s that add a component under a parent or change one's
/// fields (the `dataModelUpdate` of this catalog, whose data lives in the
/// component's own fields), `end_surface` is the end of the stream. Ids name
/// components; the tree is kept nested because that is easier for a voice
/// model to write.
///
/// A draft is append-only below the viewport: components are added at the end
/// of their parent and patched in place, so the position of what is already
/// on screen never changes (a removal only happens when the app moves a card
/// to the group it now belongs to).
class AgentSurfaceDraft {
  AgentSurfaceDraft({
    required this.id,
    required this.title,
    this.summary,
    required SurfaceNode root,
    this.source,
    // ignore: prefer_initializing_formals -- the field is private, the parameter public
  }) : _root = root;

  /// What the model calls this surface (`surface_id`).
  final String id;
  final String title;
  final String? summary;

  /// The read this surface was composed from (`list_agents`), so the app can
  /// correct it by itself when a fresher read arrives.
  final String? source;

  bool ended = false;
  SurfaceNode _root;
  int _seq = 0;

  /// Bumped on every change.
  int revision = 0;

  static const maxNodes = 120;

  SurfaceNode get root => _root;
  AgentSurfaceSpec get spec =>
      AgentSurfaceSpec(title: title, summary: summary, root: _root);
  int get count => _root.walk().length;
  SurfaceBudget get budget => SurfaceBudget(maxNodes - count);

  SurfaceNode? find(String id) =>
      _root.walk().where((n) => n.id == id).firstOrNull;

  SurfaceNode? parentOf(String id) {
    for (final n in _root.walk()) {
      if (n.children.any((c) => c.id == id)) return n;
    }
    return null;
  }

  /// The path ("r.0.2") of [id] in the tree, null when there is no such
  /// component.
  String? pathOf(String id) {
    String? visit(SurfaceNode n, String path) {
      if (n.id == id) return path;
      for (final (i, c) in n.children.indexed) {
        final found = visit(c, surfaceChildPath(path, i));
        if (found != null) return found;
      }
      return null;
    }

    return visit(_root, 'r');
  }

  /// Ids in [node]'s subtree that already exist here or repeat.
  List<String> clashes(SurfaceNode node) {
    final seen = <String>{};
    return [
      for (final n in node.walk())
        if (n.id != null && (find(n.id!) != null || !seen.add(n.id!))) n.id!,
    ];
  }

  String _fresh() {
    while (true) {
      final id = 'c${++_seq}';
      if (find(id) == null) return id;
    }
  }

  /// [node] with an id on it and on everything below it.
  SurfaceNode named(SurfaceNode node) => SurfaceNode(
    node.component,
    node.props,
    id: node.id ?? _fresh(),
    children: [for (final c in node.children) named(c)],
  );

  SurfaceNode _edit(
    SurfaceNode node,
    String target,
    SurfaceNode Function(SurfaceNode) change,
  ) {
    if (node.id == target) return change(node);
    // Nodes the change does not reach are kept as they are.
    var touched = false;
    final children = [
      for (final c in node.children)
        () {
          final edited = _edit(c, target, change);
          if (!identical(edited, c)) touched = true;
          return edited;
        }(),
    ];
    return touched ? node.copyWith(children: children) : node;
  }

  /// Appends [node] (already [named]) to the end of [parent]'s children.
  void add(String parent, SurfaceNode node) {
    _root = _edit(_root, parent, (p) {
      return p.copyWith(children: [...p.children, node]);
    });
    revision++;
  }

  /// Changes fields of [id] in place; a null value removes the field.
  void patch(String id, Map<String, Object?> props) {
    _root = _edit(_root, id, (n) {
      return n.copyWith(props: mergeNodeProps(n.props, props));
    });
    revision++;
  }

  /// Takes [id] out (only the app does: a card that moves to its new group).
  void remove(String id) {
    SurfaceNode strip(SurfaceNode n) {
      final kept = [
        for (final c in n.children)
          if (c.id != id) strip(c),
      ];
      final same =
          kept.length == n.children.length &&
          [
            for (var i = 0; i < kept.length; i++)
              identical(kept[i], n.children[i]),
          ].every((b) => b);
      return same ? n : n.copyWith(children: kept);
    }

    _root = strip(_root);
    revision++;
  }
}
