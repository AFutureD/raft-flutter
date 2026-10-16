import 'dart:convert';

import 'package:flutter/widgets.dart';

/// Generative UI for agent mode, in-house.
///
/// The model answers a question by composing a small tree of catalog
/// components ("a surface") and sending it through the `show_surface` tool.
/// The app owns what a component is: a name, a JSON Schema for its fields and
/// a widget builder. A surface that names an unknown component or field is
/// rejected whole, with the reasons, so the model can correct it.
///
/// Why not the `genui` package: see the commit that introduced this file. The
/// shape follows A2UI's catalog on purpose (a `component` discriminator, props
/// described by JSON Schema, containers holding `children`), so a catalog item
/// maps one to one onto a genui `CatalogItem` if the package becomes
/// affordable later. Only the wire format would change: genui wants a flat
/// list of components that reference each other by id, here the tree is
/// nested because that is easier for a voice model to write correctly.
typedef AgentNodeBuilder = Widget Function(
  BuildContext context,
  SurfaceNode node,
  List<Widget> children,
);

/// One component of the catalog.
class AgentCatalogItem {
  const AgentCatalogItem({
    required this.name,
    required this.description,
    required this.schema,
    required this.build,
    this.container = false,
    this.childNames,
    this.example,
    this.fold = false,
    this.line,
    this.focusable = true,
    this.internal = false,
    this.validate,
  });

  /// The value of `component` in a surface.
  final String name;

  /// What it is for, written for the model.
  final String description;

  /// JSON Schema of the node's own fields (`type: object`, `properties`,
  /// `required`). Nothing outside `properties` (and `component`, `children`
  /// for containers) is accepted.
  final Map<String, Object?> schema;
  final AgentNodeBuilder build;

  /// May hold `children`.
  final bool container;

  /// The components allowed as children; null allows every component.
  final Set<String>? childNames;

  /// A valid node of this component, shown to the model.
  final Map<String, Object?>? example;

  /// A container that folds to one summary row when its density is `summary`
  /// (the default on a phone); tapping the row shows the full cards.
  final bool fold;

  /// This component as a phrase inside a summary row ("Cindy 在做 #119").
  final String Function(SurfaceNode node)? line;

  /// Counts as one numbered item on screen (spotlight, marks). Actions do not.
  final bool focusable;

  /// Built by the app itself (the detail layer's actions): the model neither
  /// sees it in the catalog reference nor may it place one.
  final bool internal;

  /// Rules a JSON Schema subset cannot say (ids by kind, rows as wide as the
  /// columns). Called with the node's own fields once they passed the schema;
  /// returns the reasons it is refused, already prefixed with [path].
  final List<String> Function(SurfaceNode node, String path)? validate;

  Map<String, Object?> get properties =>
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  List<String> get required => [
    for (final r in (schema['required'] as List? ?? const [])) '$r',
  ];
}

/// A node of a validated surface.
class SurfaceNode {
  const SurfaceNode(
    this.component,
    this.props, {
    this.children = const [],
    this.id,
  });
  final String component;
  final Map<String, Object?> props;
  final List<SurfaceNode> children;

  /// Names the component so a later `update_component` / `add_component`
  /// can reach it (A2UI's component id). A surface that arrives whole may
  /// leave it out; a streamed one always has it.
  final String? id;

  SurfaceNode copyWith({
    Map<String, Object?>? props,
    List<SurfaceNode>? children,
    String? id,
  }) => SurfaceNode(
    component,
    props ?? this.props,
    children: children ?? this.children,
    id: id ?? this.id,
  );

  String? string(String key) {
    final v = props[key];
    return v is String && v.trim().isNotEmpty ? v : null;
  }

  int? integer(String key) => props[key] is int ? props[key] as int : null;

  bool? flag(String key) => props[key] is bool ? props[key] as bool : null;

  Map<String, Object?>? object(String key) =>
      props[key] is Map ? (props[key] as Map).cast<String, Object?>() : null;

  List<Object?> list(String key) =>
      props[key] is List ? (props[key] as List).cast<Object?>() : const [];

  /// This node and every node below it, depth first (the order the screen
  /// numbers its items).
  Iterable<SurfaceNode> walk() sync* {
    yield this;
    for (final c in children) {
      yield* c.walk();
    }
  }
}

/// A whole answer: a title, an optional one-line summary and a tree.
class AgentSurfaceSpec {
  const AgentSurfaceSpec({
    required this.title,
    required this.root,
    this.summary,
  });
  final String title;
  final String? summary;
  final SurfaceNode root;
}

/// How many more components a streamed surface may take.
class SurfaceBudget {
  SurfaceBudget(this.left) : limit = left;
  int left;
  final int limit;
}

/// The result of reading a surface: a spec, or every reason it was refused.
class SurfaceParse {
  const SurfaceParse.ok(AgentSurfaceSpec this.spec) : problems = const [];
  const SurfaceParse.rejected(this.problems) : spec = null;
  final AgentSurfaceSpec? spec;
  final List<String> problems;
  bool get ok => spec != null;
}

/// The components the model may compose, and the rules a surface must meet.
class AgentCatalog {
  AgentCatalog(Iterable<AgentCatalogItem> items)
    : items = {for (final i in items) i.name: i};

  final Map<String, AgentCatalogItem> items;

  static const maxDepth = 6;
  static const maxNodes = 80;
  static const defaultMaxLength = 400;

  AgentCatalogItem? item(String name) => items[name];

  Iterable<AgentCatalogItem> get _visible =>
      items.values.where((i) => !i.internal);

  /// Parses [raw] (a JSON string or an already decoded map) and checks it
  /// against the catalog.
  SurfaceParse parse(Object? raw) {
    Object? json = raw;
    if (raw is String) {
      try {
        json = jsonDecode(_unfence(raw));
      } on FormatException {
        return const SurfaceParse.rejected(['surface 不是合法的 JSON']);
      }
    }
    if (json is! Map) {
      return const SurfaceParse.rejected(['surface 必须是 {title, root} 对象']);
    }
    final problems = <String>[];
    for (final key in json.keys) {
      if (!const {'title', 'summary', 'root'}.contains(key)) {
        problems.add('surface 里没有字段 "$key"（只有 title、summary、root）');
      }
    }
    final title = json['title'];
    if (title is! String || title.trim().isEmpty) {
      problems.add('surface.title 必须是非空字符串');
    } else if (title.length > 60) {
      problems.add('surface.title 太长（最多 60 个字）');
    }
    final summary = json['summary'];
    if (summary != null && (summary is! String || summary.length > 200)) {
      problems.add('surface.summary 必须是不超过 200 字的字符串');
    }
    var count = 0;
    SurfaceNode? read(Object? node, String path, int depth) {
      if (++count > maxNodes) {
        if (count == maxNodes + 1) problems.add('组件太多（最多 $maxNodes 个）');
        return null;
      }
      if (depth > maxDepth) {
        problems.add('$path 嵌套太深（最多 $maxDepth 层）');
        return null;
      }
      final own = readOwn(node, path, problems);
      if (own == null) return null;
      final item = items[own.component]!;
      final here = '$path<${own.component}>';
      final children = <SurfaceNode>[];
      final rawChildren = (node as Map)['children'];
      if (rawChildren != null && item.container) {
        if (rawChildren is! List) {
          problems.add('$here.children 必须是数组');
        } else {
          for (final (i, c) in rawChildren.indexed) {
            final child = read(c, '$here.children[$i]', depth + 1);
            if (child == null) continue;
            final only = item.childNames;
            if (only != null && !only.contains(child.component)) {
              problems.add(
                '$here.children[$i] 不能放 ${child.component}（只能放：${only.join('、')}）',
              );
              continue;
            }
            children.add(child);
          }
        }
      }
      return own.copyWith(children: children);
    }

    final root = read(json['root'], 'root', 1);
    if (problems.isNotEmpty || root == null) {
      return SurfaceParse.rejected(
        problems.isEmpty ? ['surface.root 缺失'] : problems,
      );
    }
    return SurfaceParse.ok(
      AgentSurfaceSpec(
        title: (title as String).trim(),
        summary: summary is String && summary.trim().isNotEmpty
            ? summary.trim()
            : null,
        root: root,
      ),
    );
  }

  static final _idPattern = RegExp(r'^[A-Za-z0-9_\-]{1,40}$');

  /// A component's own part: its name, id and fields, checked against the
  /// catalog, without descending into `children`. Null (with the reason in
  /// [problems]) when the component is not in the catalog.
  SurfaceNode? readOwn(Object? node, String path, List<String> problems) {
    if (node is! Map) {
      problems.add('$path 必须是带 component 的对象');
      return null;
    }
    final name = node['component'];
    final item = name is String ? items[name] : null;
    if (item == null) {
      problems.add(
        '$path.component "${name ?? ''}" 不在目录里（可用：${_visible.map((i) => i.name).join('、')}）',
      );
      return null;
    }
    final here = '$path<$name>';
    final allowed = {
      'component',
      'id',
      ...item.properties.keys,
      if (item.container) 'children',
    };
    for (final key in node.keys) {
      if (!allowed.contains(key)) {
        problems.add(
          '$here 没有字段 "$key"（可用：${(allowed.toList()..remove('component')).join('、')}）',
        );
      }
    }
    final id = node['id'];
    if (id != null && (id is! String || !_idPattern.hasMatch(id))) {
      problems.add('$here.id 必须是 1 到 40 位的字母、数字、下划线或短横线');
    }
    final props = <String, Object?>{};
    final checked = problems.length;
    for (final entry in item.properties.entries) {
      final value = node[entry.key];
      if (value == null) {
        if (item.required.contains(entry.key)) {
          problems.add('$here 缺少必填字段 "${entry.key}"');
        }
        continue;
      }
      _check(
        value,
        (entry.value as Map).cast<String, Object?>(),
        '$here.${entry.key}',
        problems,
      );
      props[entry.key] = value;
    }
    final own = SurfaceNode(item.name, props, id: id is String ? id : null);
    if (item.validate != null && problems.length == checked) {
      problems.addAll(item.validate!(own, here));
    }
    return own;
  }

  /// Checks [props] against [item]'s schema (an `update_component` result).
  List<String> checkProps(
    AgentCatalogItem item,
    Map<String, Object?> props,
    String path,
  ) {
    final problems = <String>[];
    for (final entry in item.properties.entries) {
      final value = props[entry.key];
      if (value == null) {
        if (item.required.contains(entry.key)) {
          problems.add('$path 缺少必填字段 "${entry.key}"');
        }
        continue;
      }
      _check(
        value,
        (entry.value as Map).cast<String, Object?>(),
        '$path.${entry.key}',
        problems,
      );
    }
    if (item.validate != null && problems.isEmpty) {
      problems.addAll(item.validate!(SurfaceNode(item.name, props), path));
    }
    return problems;
  }

  /// Reads a subtree one component at a time: a component that fails the
  /// catalog or [ground] is dropped with its subtree and its reasons are
  /// added to [problems]; the others are kept. [budget] counts how many more
  /// nodes may be accepted. Null when [raw] itself is dropped.
  SurfaceNode? salvage(
    Object? raw, {
    required List<String> problems,
    required SurfaceBudget budget,
    SurfaceNode? parent,
    String path = 'component',
    int depth = 1,
    List<String> Function(SurfaceNode shallow, SurfaceNode? parent)? ground,
  }) {
    if (depth > maxDepth) {
      problems.add('$path 嵌套太深（最多 $maxDepth 层）');
      return null;
    }
    if (budget.left <= 0) {
      problems.add('组件太多（一屏最多 ${budget.limit} 个）');
      return null;
    }
    final own = <String>[];
    final node = readOwn(raw, path, own);
    if (node != null && own.isEmpty && ground != null) {
      own.addAll(ground(node, parent));
    }
    if (node == null || own.isNotEmpty) {
      problems.addAll(own);
      return null;
    }
    budget.left--;
    final item = items[node.component]!;
    final rawChildren = (raw as Map)['children'];
    final children = <SurfaceNode>[];
    if (rawChildren != null && item.container) {
      final here = '$path<${node.component}>';
      if (rawChildren is! List) {
        problems.add('$here.children 必须是数组');
      } else {
        for (final (i, c) in rawChildren.indexed) {
          final child = salvage(
            c,
            problems: problems,
            budget: budget,
            parent: node,
            path: '$here.children[$i]',
            depth: depth + 1,
            ground: ground,
          );
          if (child == null) continue;
          final only = item.childNames;
          if (only != null && !only.contains(child.component)) {
            problems.add(
              '$here.children[$i] 不能放 ${child.component}（只能放：${only.join('、')}）',
            );
            continue;
          }
          children.add(child);
        }
      }
    }
    return node.copyWith(children: children);
  }

  static String _unfence(String raw) {
    final t = raw.trim();
    final m = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
    return m == null ? t : m[1]!;
  }

  /// A JSON Schema subset check: type, enum, length, items, nested objects.
  static void _check(
    Object? value,
    Map<String, Object?> schema,
    String path,
    List<String> problems,
  ) {
    final either = schema['oneOf'];
    if (either is List) {
      final reasons = <String>[];
      for (final alternative in either) {
        final own = <String>[];
        _check(value, (alternative as Map).cast<String, Object?>(), path, own);
        if (own.isEmpty) return;
        reasons.add(own.first);
      }
      problems.add(reasons.join(' 或 '));
      return;
    }
    switch (schema['type']) {
      case 'string':
        if (value is! String) {
          problems.add('$path 必须是字符串');
          return;
        }
        final max = (schema['maxLength'] as int?) ?? defaultMaxLength;
        if (value.length > max) problems.add('$path 太长（最多 $max 个字）');
        final choices = schema['enum'] as List?;
        if (choices != null && !choices.contains(value)) {
          problems.add('$path 只能是 ${choices.join('、')} 之一，不能是 "$value"');
        }
      case 'integer':
        if (value is! int) problems.add('$path 必须是整数');
      case 'number':
        if (value is! num) problems.add('$path 必须是数字');
      case 'boolean':
        if (value is! bool) problems.add('$path 必须是 true 或 false');
      case 'array':
        if (value is! List) {
          problems.add('$path 必须是数组');
          return;
        }
        final min = (schema['minItems'] as int?) ?? 0;
        final max = (schema['maxItems'] as int?) ?? 40;
        if (value.length < min || value.length > max) {
          problems.add('$path 需要 $min 到 $max 项');
        }
        final items = schema['items'];
        if (items is Map) {
          for (final (i, v) in value.indexed) {
            _check(v, items.cast<String, Object?>(), '$path[$i]', problems);
          }
        }
      case 'object':
        if (value is! Map) {
          problems.add('$path 必须是对象');
          return;
        }
        final props =
            (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
        for (final key in value.keys) {
          if (!props.containsKey(key)) {
            problems.add('$path 没有字段 "$key"（可用：${props.keys.join('、')}）');
          }
        }
        for (final r in (schema['required'] as List? ?? const [])) {
          if (value[r] == null) problems.add('$path 缺少必填字段 "$r"');
        }
        for (final entry in props.entries) {
          if (value[entry.key] != null) {
            _check(
              value[entry.key],
              (entry.value as Map).cast<String, Object?>(),
              '$path.${entry.key}',
              problems,
            );
          }
        }
    }
  }

  /// The component reference the model is given: every component with its
  /// fields, and one valid example each.
  String describe() {
    final lines = <String>[];
    for (final item in _visible) {
      final fields = [
        for (final e in item.properties.entries)
          '${e.key}${item.required.contains(e.key) ? '*' : ''}:${_typeOf((e.value as Map).cast<String, Object?>())}',
        if (item.container)
          'children:[${(item.childNames ?? _visible.map((i) => i.name)).join('|')}]',
      ];
      lines.add('- ${item.name}（${item.description}）{${fields.join(', ')}}');
      if (item.example != null) lines.add('  例：${jsonEncode(item.example)}');
    }
    return lines.join('\n');
  }

  static String _typeOf(Map<String, Object?> schema) {
    final either = schema['oneOf'];
    if (either is List) {
      return either
          .map((a) => _typeOf((a as Map).cast<String, Object?>()))
          .join('|');
    }
    final choices = schema['enum'] as List?;
    if (choices != null) return choices.join('|');
    if (schema['type'] == 'array') {
      final items = schema['items'];
      return '[${items is Map ? _typeOf(items.cast<String, Object?>()) : 'any'}]';
    }
    if (schema['type'] == 'object') {
      final props = (schema['properties'] as Map?)?.keys ?? const [];
      final req =
          (schema['required'] as List?)?.map((e) => '$e').toSet() ??
          const <String>{};
      return '{${props.map((p) => '$p${req.contains(p) ? '*' : ''}').join(',')}}';
    }
    return '${schema['type']}';
  }
}

/// How a folding container is drawn: `summary` or `detail`.
const agentDensities = ['summary', 'detail'];

/// The `density` field every container takes.
const Map<String, Object?> agentDensityField = {
  'type': 'string',
  'enum': agentDensities,
  'description': 'summary 摘要：每组只占一行（手机上不写就是它）；detail 展开成完整卡片，只在用户要求展开这一组时才写',
};

/// Where a node sits in a surface, for naming it: `r`, `r.0`, `r.0.2`.
String surfaceChildPath(String path, int index) => '$path.$index';

/// The paths of the containers drawn as one summary row. A container
/// follows its own `density`, else the nearest enclosing one, else [compact]
/// (summary on a phone, detail on a wide screen); a path in [expanded] was
/// opened by the person and shows in full. Cards and the frame sent to the
/// model share this, so item numbers always agree.
Set<String> foldedPaths(
  AgentCatalog catalog,
  SurfaceNode root, {
  required bool compact,
  Set<String> expanded = const {},
}) {
  final folded = <String>{};
  void visit(SurfaceNode n, String path, String? inherited) {
    final own = n.string('density');
    final density = own ?? inherited;
    if (catalog.item(n.component)?.fold ?? false) {
      final summary =
          (density ?? (compact ? 'summary' : 'detail')) == 'summary';
      // A group with nothing in it yet (a streamed skeleton) shows its title.
      if (summary && !expanded.contains(path) && n.children.isNotEmpty) {
        folded.add(path);
        return;
      }
    }
    for (final (i, c) in n.children.indexed) {
      visit(c, surfaceChildPath(path, i), density);
    }
  }

  visit(root, 'r', null);
  return folded;
}

/// The number each item on screen has, by path: a folded container counts as
/// one item, a leaf is one, a plain container none. The same numbers the
/// cards are tagged with and the frame sent to the model uses.
Map<String, int> focusNumbers(
  AgentCatalog catalog,
  SurfaceNode root,
  Set<String> folded,
) {
  final numbers = <String, int>{};
  void visit(SurfaceNode n, String path) {
    if (folded.contains(path)) {
      numbers[path] = numbers.length + 1;
      return;
    }
    final item = catalog.item(n.component);
    if (item != null && !item.container && item.focusable) {
      numbers[path] = numbers.length + 1;
    }
    for (final (i, c) in n.children.indexed) {
      visit(c, surfaceChildPath(path, i));
    }
  }

  visit(root, 'r');
  return numbers;
}

/// The actions a detail layer offers (通过 / 打开讨论 / 稍后), handed down to
/// the `ActionRow` inside it. Nothing else may act, so a surface the model
/// composes cannot carry them.
class AgentActionScope extends InheritedWidget {
  const AgentActionScope({
    super.key,
    required this.onAction,
    required super.child,
  });

  /// `approve`, `open` or `later`.
  final void Function(String action) onAction;

  static AgentActionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentActionScope>();

  @override
  bool updateShouldNotify(AgentActionScope old) => false;
}
