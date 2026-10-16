import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// How much of a component is drawn, as a preset: `minimum` is one line
/// (the headline), `medium` the headline and one line of meta, `detail`
/// everything the app knows.
enum AgentLevel { minimum, medium, detail }

/// The type scale. `compact` is the arm's-length phone scale (headline 26,
/// nothing under 16); `regular` and `large` only go up from there.
enum AgentSize { compact, regular, large }

/// The type sizes of one entity card.
@immutable
class AgentTypeScale {
  const AgentTypeScale({
    required this.headline,
    required this.meta,
    required this.body,
    required this.small,
  });
  final double headline, meta, body, small;

  static const compact = AgentTypeScale(
    headline: 26,
    meta: 18,
    body: 18,
    small: 16,
  );
  static const regular = AgentTypeScale(
    headline: 30,
    meta: 21,
    body: 21,
    small: 18,
  );
  static const large = AgentTypeScale(
    headline: 36,
    meta: 24,
    body: 24,
    small: 20,
  );

  /// The tighter scale a wide screen read from a desk has by default.
  static const wide = AgentTypeScale(
    headline: 20,
    meta: 17,
    body: 18,
    small: 16,
  );

  static AgentTypeScale of(AgentSize size) => switch (size) {
    AgentSize.compact => compact,
    AgentSize.regular => regular,
    AgentSize.large => large,
  };
}

/// What one component can show: the elements it is made of (each can be
/// present or absent), what each preset level shows, and the defaults.
@immutable
class AgentDisplayKind {
  const AgentDisplayKind._(
    this.key,
    this.elements,
    this._presets,
    this.lines,
    this.legacy,
    this.words,
    this.textLines,
  );

  /// `message`, `task`… for the entity cards, else the component name.
  final String key;
  final List<String> elements;
  final Map<AgentLevel, Set<String>> _presets;

  /// How many lines of the main text the preset levels allow: minimum,
  /// medium, detail.
  final (int, int, int) lines;

  /// The level a component has when nobody says one: what it always showed
  /// before levels existed.
  final AgentLevel legacy;

  /// What each element is, for the model.
  final Map<String, String> words;

  /// Whether the component has a main text `lines` can clamp.
  final bool textLines;

  Set<String> preset(AgentLevel level) => _presets[level]!;

  int defaultLines(AgentLevel level) => switch (level) {
    AgentLevel.minimum => lines.$1,
    AgentLevel.medium => lines.$2,
    AgentLevel.detail => lines.$3,
  };

  /// A line for the model: the names, and what each preset shows.
  String get guide {
    String names(Set<String> s) => [
      for (final e in elements)
        if (s.contains(e)) e,
    ].join('、');
    return '$key：${elements.join('、')}。'
        'minimum=${names(preset(AgentLevel.minimum))}；'
        'medium=${names(preset(AgentLevel.medium))}；'
        'detail=${names(preset(AgentLevel.detail))}';
  }
}

AgentDisplayKind _kind(
  String key,
  Map<String, String> words, {
  required String minimum,
  String? medium,
  String? detail,
  (int, int, int) lines = (1, 2, 3),
  AgentLevel legacy = AgentLevel.medium,
  bool textLines = true,
}) {
  final elements = words.keys.toList();
  Set<String> set(String? s) =>
      s == null ? elements.toSet() : s.split(' ').where((e) => e != '').toSet();
  final medium0 = set(medium);
  final detail0 = set(detail);
  final minimum0 = set(minimum);
  for (final e in [...minimum0, ...medium0, ...detail0]) {
    assert(elements.contains(e), '$key has no element $e');
  }
  return AgentDisplayKind._(
    key,
    List.unmodifiable(elements),
    {
      AgentLevel.minimum: minimum0,
      AgentLevel.medium: medium0,
      AgentLevel.detail: detail0,
    },
    lines,
    legacy,
    Map.unmodifiable(words),
    textLines,
  );
}

/// The element inventories, by component. Entity cards are keyed by
/// [AgentEntityKind] name (`message`, `task`, `agent`, `channel`, `member`,
/// `computer`, `file`), the rest by their catalog name.
final Map<String, AgentDisplayKind> agentDisplayKinds = Map.unmodifiable({
  for (final k in [
    _kind(
      'message',
      {
        'avatar': '头像',
        'author': '发送者',
        'time': '时间',
        'channel': '频道',
        'text': '正文',
        'attachments': '附件个数',
        'reactions': '表情回应',
        'thread_count': '回复条数',
        'handle': '编号 ① ② ③',
      },
      minimum: 'text handle',
      medium: 'avatar author time channel text attachments handle',
      lines: (1, 2, 8),
    ),
    _kind(
      'task',
      {
        'number': '任务编号',
        'title': '标题',
        'status': '状态',
        'assignee': '负责人',
        'channel': '频道',
        'updated': '更新时间',
        'description': '描述',
        'latest_progress': '最新进展',
        'handle': '编号 ① ② ③',
      },
      minimum: 'title handle',
      medium: 'number title status assignee channel updated handle',
      lines: (1, 2, 3),
    ),
    _kind(
      'agent',
      {
        'avatar': '头像',
        'name': '名字',
        'state': '状态',
        'activity': '正在做什么',
        'since': '持续多久',
        'computer': '所在电脑',
        'channel': '所在频道',
        'model': '模型',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name handle',
      medium: 'avatar name state activity computer handle',
      lines: (1, 2, 3),
    ),
    _kind(
      'channel',
      {
        'name': '频道名',
        'description': '简介',
        'unread': '未读数',
        'mentions': '@我',
        'last_activity': '最近活动',
        'members': '成员数',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name handle',
      medium: 'name unread mentions last_activity handle',
      lines: (1, 2, 3),
    ),
    _kind(
      'member',
      {
        'avatar': '头像',
        'name': '名字',
        'role': '角色',
        'presence': '在线状态（App 知道时才有）',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name handle',
      lines: (1, 1, 2),
    ),
    _kind(
      'computer',
      {
        'name': '名字',
        'online': '在线状态',
        'runtimes': '运行环境',
        'agents': 'Agent 个数',
        'version': '版本',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name handle',
      medium: 'name online runtimes agents handle',
      lines: (1, 1, 2),
    ),
    _kind(
      'file',
      {
        'name': '文件名',
        'type': '类型',
        'size': '大小',
        'thumbnail': '缩略图',
        'author': '上传者',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name handle',
      medium: 'name type size thumbnail handle',
      lines: (1, 2, 2),
    ),
    _kind(
      'AgentStatusCard',
      {
        'name': '名字',
        'state': '状态贴纸',
        'activity': '正在做什么',
        'since': '持续多久',
        'channel': '频道',
        'handle': '编号 ① ② ③',
      },
      minimum: 'name state handle',
      medium: 'name state activity handle',
      lines: (1, 2, 2),
      legacy: AgentLevel.detail,
    ),
    _kind(
      'TaskCard',
      {
        'number': '任务编号',
        'status': '状态贴纸',
        'title': '标题',
        'assignee': '负责人',
        'channel': '频道',
        'latest_progress': '最新进展',
        'ask': '“要你做”',
        'handle': '编号 ① ② ③',
      },
      minimum: 'title handle',
      medium: 'number status title assignee channel ask handle',
      lines: (1, 2, 3),
      legacy: AgentLevel.detail,
    ),
    _kind(
      'MessageQuote',
      {
        'author': '发送者',
        'time': '时间',
        'channel': '频道',
        'text': '原话',
        'bar': '左边的竖线',
        'handle': '编号 ① ② ③',
      },
      minimum: 'text handle',
      medium: 'author time text bar handle',
      lines: (1, 3, 5),
      legacy: AgentLevel.detail,
    ),
    _kind(
      'StatRow',
      {'label': '数字下面的说明', 'handle': '编号 ① ② ③'},
      minimum: 'handle',
      legacy: AgentLevel.detail,
      textLines: false,
    ),
    _kind(
      'AgentStatusGroup',
      {'title': '组标题', 'count': '个数徽标', 'collapse': '折叠成一行时的展开箭头'},
      minimum: 'title',
      legacy: AgentLevel.detail,
      textLines: false,
    ),
    _kind(
      'Section',
      {'title': '小标题', 'count': '个数徽标', 'collapse': '折叠成一行时的展开箭头'},
      minimum: 'title',
      textLines: false,
    ),
    _kind(
      'Table',
      {'header': '表头', 'borders': '行间的线', 'zebra': '隔行底色'},
      minimum: 'header',
      medium: 'header borders',
      lines: (1, 3, 3),
    ),
    _kind(
      'Timeline',
      {'time': '时间', 'icon': '左边的圆点和竖线', 'title': '事件', 'entity': '附带的东西'},
      minimum: 'title',
      medium: 'time icon title entity',
      detail: 'time icon title entity',
      lines: (1, 3, 3),
    ),
    _kind(
      'CodeBlock',
      {'title': '文件名', 'line_numbers': '行号', 'more': '“还有 N 行”'},
      minimum: '',
      medium: 'title more',
      textLines: false,
    ),
    _kind(
      'Callout',
      {'icon': '图标', 'text': '那句话'},
      minimum: 'text',
      medium: 'icon text',
      lines: (1, 4, 4),
    ),
    _kind(
      'ConfirmCard',
      {'label': '“将要修改”标签', 'field_names': '每项上面的字段名'},
      minimum: '',
      medium: 'label field_names',
      lines: (3, 3, 3),
    ),
  ])
    k.key: k,
});

/// Every element name any component has, in the order of the inventories.
List<String> agentAllElements([Iterable<String>? kinds]) {
  final out = <String>[];
  for (final key in kinds ?? agentDisplayKinds.keys) {
    for (final e in agentDisplayKinds[key]?.elements ?? const <String>[]) {
      if (!out.contains(e)) out.add(e);
    }
  }
  return out;
}

const _levelNames = ['minimum', 'medium', 'detail'];
const _sizeNames = ['compact', 'regular', 'large'];

/// What the model says about how a component looks: a preset [level], and
/// per-element overrides in [show]; [lines] clamps the main text and [size]
/// picks the type scale. Everything is optional; what is not said is
/// inherited (`childDisplay` of a list), then the screen's default.
@immutable
class DisplaySpec {
  const DisplaySpec({this.level, this.show = const {}, this.lines, this.size});

  final AgentLevel? level;

  /// Element name to present (true) or absent (false); beats the preset.
  final Map<String, bool> show;

  /// 1 to 8, the lines of the main text.
  final int? lines;
  final AgentSize? size;

  static const none = DisplaySpec();

  bool get isEmpty =>
      level == null && show.isEmpty && lines == null && size == null;

  static const maxLines = 8;

  /// Reads what the schema let through; anything else is left out.
  factory DisplaySpec.fromJson(Object? json) {
    if (json is! Map) return none;
    final show = json['show'];
    final lines = json['lines'];
    return DisplaySpec(
      level: AgentLevel.values
          .where((l) => l.name == json['level'])
          .firstOrNull,
      show: show is Map
          ? {
              for (final e in show.entries)
                if (e.key is String && e.value is bool)
                  e.key as String: e.value as bool,
            }
          : const {},
      lines: lines is int ? lines.clamp(1, maxLines) : null,
      size: AgentSize.values.where((s) => s.name == json['size']).firstOrNull,
    );
  }

  Map<String, Object?> toJson() => {
    if (level != null) 'level': level!.name,
    if (show.isNotEmpty) 'show': {...show},
    'lines': ?lines,
    if (size != null) 'size': size!.name,
  };

  /// This spec on top of [base]: what this says wins, the rest is [base]'s.
  DisplaySpec over(DisplaySpec? base) {
    if (base == null || base.isEmpty) return this;
    return DisplaySpec(
      level: level ?? base.level,
      show: {...base.show, ...show},
      lines: lines ?? base.lines,
      size: size ?? base.size,
    );
  }

  /// What is drawn for [kind]: the preset of the level (this one's, else
  /// [fallbackLevel], else the kind's legacy level) with [show] applied.
  /// Names the kind has no element for are ignored (a list's `childDisplay`
  /// reaches children of every kind).
  AgentDisplay resolve(String kind, {AgentLevel? fallbackLevel}) {
    final k = agentDisplayKinds[kind];
    final lv = level ?? fallbackLevel ?? k?.legacy ?? AgentLevel.detail;
    if (k == null) return AgentDisplay._(lv, const {}, lines ?? 1, size);
    final shown = {...k.preset(lv)};
    for (final e in show.entries) {
      if (!k.elements.contains(e.key)) continue;
      e.value ? shown.add(e.key) : shown.remove(e.key);
    }
    return AgentDisplay._(
      lv,
      shown,
      (lines ?? k.defaultLines(lv)).clamp(1, maxLines),
      size,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DisplaySpec &&
      other.level == level &&
      other.lines == lines &&
      other.size == size &&
      mapEquals(other.show, show);

  @override
  int get hashCode =>
      Object.hash(level, lines, size, Object.hashAllUnordered(show.entries));

  @override
  String toString() => 'DisplaySpec(${toJson()})';

  /// The reasons [json] (a `display`) is not valid for [kind], worded for
  /// the model. Types are the schema's job; this is what it cannot say:
  /// element names that exist, but not on this kind.
  static List<String> problems(Object? json, String kind, String path) {
    final k = agentDisplayKinds[kind];
    if (k == null || json is! Map) return const [];
    final show = json['show'];
    if (show is! Map) return const [];
    return [
      for (final name in show.keys)
        if (!k.elements.contains(name))
          '$path.show 没有元素 "$name"（$kind 可用：${k.elements.join('、')}）',
    ];
  }
}

/// A [DisplaySpec] resolved for one component.
@immutable
class AgentDisplay {
  const AgentDisplay._(this.level, this._shown, this.lines, this.size);

  final AgentLevel level;
  final Set<String> _shown;

  /// How many lines the main text may take.
  final int lines;
  final AgentSize? size;

  bool has(String element) => _shown.contains(element);

  /// The entity card's type sizes: the one asked for, else [fallback].
  AgentTypeScale scale(AgentTypeScale fallback) =>
      size == null ? fallback : AgentTypeScale.of(size!);

  Set<String> get shown => Set.unmodifiable(_shown);

  /// Type scale for the surface cards and blocks: a multiplier on the sizes
  /// they have always had.
  double factor({bool surface = false}) => switch (size) {
    null || AgentSize.compact => 1,
    AgentSize.regular => surface ? 1.35 : 1.15,
    AgentSize.large => surface ? 1.6 : 1.3,
  };
}

/// A [DisplaySpec] of the JSON a node holds under [key].
DisplaySpec agentDisplayOf(
  Map<String, Object?> props, [
  String key = 'display',
]) => DisplaySpec.fromJson(props[key]);

/// `update_component` on `display` or `childDisplay` changes only what it
/// names: `show` entries merge one by one, and a null removes one (back to
/// the preset). Anything else is merged by the caller like any field.
Object? mergeDisplayJson(Object? base, Object? patch) {
  if (patch == null) return null;
  if (base is! Map || patch is! Map) return patch;
  final out = <String, Object?>{...base.cast<String, Object?>()};
  for (final e in patch.entries) {
    final key = '${e.key}';
    if (key == 'show') {
      final show = <String, Object?>{
        if (out['show'] is Map) ...(out['show'] as Map).cast<String, Object?>(),
      };
      if (e.value is Map) {
        for (final s in (e.value as Map).entries) {
          if (s.value == null) {
            show.remove('${s.key}');
          } else {
            show['${s.key}'] = s.value;
          }
        }
      }
      if (show.isEmpty) {
        out.remove('show');
      } else {
        out['show'] = show;
      }
    } else if (e.value == null) {
      out.remove(key);
    } else {
      out[key] = e.value;
    }
  }
  return out.isEmpty ? null : out;
}

/// The fields of a node after an `update_component` with [patch]: shallow,
/// except that `display` and `childDisplay` merge (see [mergeDisplayJson]).
Map<String, Object?> mergeNodeProps(
  Map<String, Object?> props,
  Map<String, Object?> patch,
) {
  final merged = {...props};
  for (final e in patch.entries) {
    final Object? value = const {'display', 'childDisplay'}.contains(e.key)
        ? mergeDisplayJson(props[e.key], e.value)
        : e.value;
    if (value == null) {
      merged.remove(e.key);
    } else {
      merged[e.key] = value;
    }
  }
  return merged;
}

/// The JSON Schema of a `display` (or a list's `childDisplay`) field for the
/// components [kinds]: `level`, `show` with one boolean per element name,
/// `lines` and `size`. Names outside it are refused, with the valid ones
/// listed.
Map<String, Object?> agentDisplaySchema(
  Iterable<String> kinds, {
  bool childDisplay = false,
  String? note,
}) {
  final kindList = kinds.toList();
  final lines = kindList.any((k) => agentDisplayKinds[k]?.textLines ?? false);
  final words = <String, String>{};
  for (final key in kinds) {
    for (final e
        in agentDisplayKinds[key]?.words.entries ??
            const <MapEntry<String, String>>[]) {
      words.putIfAbsent(e.key, () => e.value);
    }
  }
  return {
    'type': 'object',
    'x-describe': true,
    'description':
        '${childDisplay ? '所有子组件的显示方式，子组件自己写了 display 的以它为准。' : '这个组件怎么显示。'}'
        'level 是预设：minimum 只显示一行标题，medium 标题加一行说明，detail 显示全部；'
        'show 是在预设上逐项开关，如 {"avatar":false} 去掉头像、{"reactions":true} 加上表情回应；'
        '${lines ? 'lines 限制主要文字最多几行（1 到 ${DisplaySpec.maxLines}）；' : ''}'
        'size 是字号，compact 默认，regular 更大，large 最大。都不写就用屏幕的默认。'
        '${note ?? ''}',
    'properties': {
      'level': {
        'type': 'string',
        'enum': _levelNames,
        'description': '预设：minimum 一行 / medium 标题加一行说明 / detail 全部',
      },
      'show': {
        'type': 'object',
        'description':
            '逐项开关；元素：${words.entries.map((e) => '${e.key}（${e.value}）').join('、')}',
        'properties': {
          for (final e in words.entries)
            e.key: {'type': 'boolean', 'description': e.value},
        },
      },
      if (lines)
        'lines': {
          'type': 'integer',
          'minimum': 1,
          'maximum': DisplaySpec.maxLines,
          'description': '主要文字最多几行',
        },
      'size': {
        'type': 'string',
        'enum': _sizeNames,
        'description': '字号：compact / regular / large',
      },
    },
  };
}

/// The one-paragraph reference of what [kinds] can show, for the model.
String agentDisplayGuide(Iterable<String> kinds) => [
  for (final k in kinds)
    if (agentDisplayKinds[k] != null) agentDisplayKinds[k]!.guide,
].join('\n');

/// Smooth size changes: the duration and curve every component uses when a
/// property change makes it taller or shorter.
const agentResizeDuration = Duration(milliseconds: 240);
const agentResizeCurve = Curves.easeOutCubic;
