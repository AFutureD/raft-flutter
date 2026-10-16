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

  Map<String, Object?> get properties =>
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  List<String> get required => [
    for (final r in (schema['required'] as List? ?? const [])) '$r',
  ];
}

/// A node of a validated surface.
class SurfaceNode {
  const SurfaceNode(this.component, this.props, [this.children = const []]);
  final String component;
  final Map<String, Object?> props;
  final List<SurfaceNode> children;

  String? string(String key) {
    final v = props[key];
    return v is String && v.trim().isNotEmpty ? v : null;
  }

  int? integer(String key) => props[key] is int ? props[key] as int : null;

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
      if (node is! Map) {
        problems.add('$path 必须是带 component 的对象');
        return null;
      }
      final name = node['component'];
      final item = name is String ? items[name] : null;
      if (item == null) {
        problems.add(
          '$path.component "${name ?? ''}" 不在目录里（可用：${items.keys.join('、')}）',
        );
        return null;
      }
      final here = '$path<$name>';
      final allowed = {
        'component',
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
      final props = <String, Object?>{};
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
      final children = <SurfaceNode>[];
      final rawChildren = node['children'];
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
      return SurfaceNode(item.name, props, children);
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
    for (final item in items.values) {
      final fields = [
        for (final e in item.properties.entries)
          '${e.key}${item.required.contains(e.key) ? '*' : ''}:${_typeOf((e.value as Map).cast<String, Object?>())}',
        if (item.container)
          'children:[${(item.childNames ?? items.keys).join('|')}]',
      ];
      lines.add('- ${item.name}（${item.description}）{${fields.join(', ')}}');
      if (item.example != null) lines.add('  例：${jsonEncode(item.example)}');
    }
    return lines.join('\n');
  }

  static String _typeOf(Map<String, Object?> schema) {
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
