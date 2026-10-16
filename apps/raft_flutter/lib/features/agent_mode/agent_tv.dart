import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

import 'references/agent_handle_tag.dart';

/// Phone side of agent mode on an external display (Android presentation
/// display). The phone keeps input; the TV mirrors the layer stack.
class AgentPresentation {
  AgentPresentation._();
  static final instance = AgentPresentation._();
  static const _channel = MethodChannel('app.raft/agent-presentation');

  int? _shown;
  VoidCallback? onDisplaysChanged;

  /// Shows agent mode on the first presentation display, if any.
  Future<bool> attach() async {
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'displaysChanged') onDisplaysChanged?.call();
      });
      final displays = await _channel.invokeListMethod<Map>('displays') ?? [];
      if (displays.isEmpty) {
        _shown = null;
        return false;
      }
      final id = displays.first['id'] as int;
      if (_shown != id) {
        await _channel.invokeMethod('show', {'id': id});
        _shown = id;
      }
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> send(Map<String, Object?> frame) async {
    if (_shown == null) return;
    try {
      await _channel.invokeMethod('frame', frame);
    } on PlatformException {
      // The TV may have gone away between frames; the next attach recovers.
    }
  }

  Future<void> detach() async {
    _channel.setMethodCallHandler(null);
    onDisplaysChanged = null;
    if (_shown == null) return;
    _shown = null;
    try {
      await _channel.invokeMethod('hide');
    } on PlatformException {
      /* already gone */
    } on MissingPluginException {
      /* not Android */
    }
  }
}

/// Entry point of the second engine that renders on the external display.
@pragma('vm:entry-point')
void agentTvMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _AgentTvApp());
}

class _AgentTvApp extends StatefulWidget {
  const _AgentTvApp();
  @override
  State<_AgentTvApp> createState() => _AgentTvAppState();
}

class _AgentTvAppState extends State<_AgentTvApp> {
  static const _channel = MethodChannel('app.raft/agent-presentation-tv');
  Map<String, Object?>? frame;
  final _spotlight = AgentSpotlightController();
  final _marks = AgentMarkController();

  /// Applies a frame from the phone, including what is lifted and marked.
  void _show(Map<String, Object?> next) {
    setState(() => frame = next);
    _spotlight.sync(
      next['spotlight'] as String?,
      enter: next['spotlightEnter'] == true,
    );
    final marks = [
      for (final m in (next['marks'] as List?) ?? const [])
        ?AgentMark.fromJson(m),
    ];
    final now = _marks.marks;
    final same =
        now.length == marks.length &&
        [
          for (var i = 0; i < now.length; i++)
            now[i].itemId == marks[i].itemId &&
                now[i].phrase == marks[i].phrase,
        ].every((v) => v);
    if (!same) _marks.sync(marks);
  }

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'frame' && call.arguments is Map) {
        _show(Map<String, Object?>.from(call.arguments as Map));
      }
    });
    unawaited(
      _channel.invokeMethod<Object?>('ready').then((latest) {
        if (latest is Map && mounted) {
          _show(Map<String, Object?>.from(latest));
        }
      }, onError: (_) {}),
    );
  }

  ThemeData _theme(String? id) => switch (id) {
    'elegant-light' => raftTheme(RaftFamily.elegant),
    'elegant-dark' => raftTheme(RaftFamily.elegant, dark: true),
    _ => raftTheme(RaftFamily.brutal),
  };

  @override
  Widget build(BuildContext context) {
    final f = frame;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(f?['theme'] as String?),
      home: Builder(
        builder: (context) {
          final t = RaftAgentTheme.of(context);
          final layers = [
            for (final l in (f?['layers'] as List?) ?? const [])
              if (l is Map) Map<String, Object?>.from(l),
          ];
          final top = layers.isEmpty ? null : layers.last;
          if (top != null && top['id'] == 'attention' && top['tv'] is Map) {
            return Scaffold(
              backgroundColor: t.canvas,
              body: AgentTvAttention(
                frame: Map<String, Object?>.from(top['tv'] as Map),
              ),
            );
          }
          return Scaffold(
            backgroundColor: t.canvas,
            body: top == null
                ? Center(child: Text('Raft · Agent 模式', style: t.heading(28)))
                : AgentMarks(
                    controller: _marks,
                    child: AgentSpotlight(
                      controller: _spotlight,
                      child: AgentTvLayer(
                        key: ValueKey(top['id']),
                        frame: top,
                        caption: '${f?['caption'] ?? ''}',
                        mood: '${f?['mood'] ?? ''}',
                        focused: f?['spotlight'] as String?,
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

/// Renders one serialized layer (see [agentLayerFrame]).
class AgentFrameView extends StatelessWidget {
  const AgentFrameView({
    super.key,
    required this.frame,
    this.onOpen,
    this.focusPrefix,
  });
  final Map<String, Object?> frame;

  /// When set, every item is an [AgentFocusable] with id `prefix#n`, n
  /// counting items (not section labels) from 1 as the agent sees them.
  final String? focusPrefix;

  /// Phone only: opens the item's channel as a new layer.
  final void Function(String channelId)? onOpen;

  static AgentPriority _priority(Object? v) => AgentPriority.values.firstWhere(
    (p) => p.name == v,
    orElse: () => AgentPriority.progress,
  );

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final i in (frame['items'] as List?) ?? const [])
        if (i is Map) Map<String, Object?>.from(i),
    ];
    var n = 0;
    Widget focusable(Widget child) {
      n++;
      final prefix = focusPrefix;
      return prefix == null
          ? child
          : AgentFocusable(
              id: '$prefix#$n',
              child: AgentHandleTag(focusId: '$prefix#$n', child: child),
            );
    }

    return AgentLayerFrame(
      title: '${frame['title'] ?? ''}',
      meta: frame['meta'] as String?,
      loading: frame['loading'] == true,
      summary: frame['summary'] == null
          ? null
          : TextSpan(text: '${frame['summary']}'),
      children: [
        for (final i in items)
          switch (i['kind']) {
            'section' => AgentSectionLabel('${i['text'] ?? ''}'),
            'message' => focusable(
              AgentMessageTile(
                sender: '${i['sender'] ?? ''}',
                time: i['time'] as String?,
                text: '${i['text'] ?? ''}',
              ),
            ),
            _ => focusable(
              AgentPriorityCard(
                onTap: onOpen == null || i['channelId'] is! String
                    ? null
                    : () => onOpen!(i['channelId'] as String),
                priority: _priority(i['priority']),
                label: i['label'] as String?,
                weight: (i['weight'] as int?) ?? 0,
                title: '${i['title'] ?? ''}',
                detail: i['detail'] as String?,
                chips: [
                  for (final c in (i['chips'] as List?) ?? const [])
                    AgentChip('$c'),
                ],
              ),
            ),
          },
      ],
    );
  }
}

/// What the TV mirrors while the attention layer is in front: the top three
/// items in 10-foot type, dark, no buttons ("在手机上处理"), and a caption
/// strip with what the agent says. Built from [AgentAttention.tvFrame].
class AgentTvAttention extends StatelessWidget {
  const AgentTvAttention({super.key, required this.frame});
  final Map<String, Object?> frame;

  static const ink = Color(0xff141110);
  static const _cream = Color(0xfffff0bd);
  static const _rank = [
    Color(0xffff5a69),
    Color(0xff2ccbf0),
    Color(0xffffd441),
  ];

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return AgentCanvas(
      child: LayoutBuilder(
        builder: (context, size) {
          // 10-foot type: 22 logical px of headline per 540 px of height,
          // never below the phone sizes.
          final s = (size.maxHeight / 540).clamp(1.0, 3.0);
          TextStyle heading(double v, [Color color = ink]) => t
              .heading(v * s, weight: FontWeight.w900)
              .copyWith(color: color, height: 1.2);
          TextStyle body(double v, [Color color = ink]) => t
              .body(v * s, weight: FontWeight.w800, color: color)
              .copyWith(height: 1.2);
          final items = [
            for (final i in (frame['items'] as List?) ?? const [])
              if (i is Map) Map<String, Object?>.from(i),
          ];
          int count(String k) => (frame[k] as int?) ?? 0;
          final caption = '${frame['caption'] ?? ''}';
          final mood = '${frame['mood'] ?? ''}';
          Widget badge(int n, Color color) => Container(
            padding: EdgeInsets.symmetric(horizontal: 8 * s),
            constraints: BoxConstraints(minWidth: 34 * s),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(9 * s),
              border: Border.all(color: ink, width: 2.5 * s),
            ),
            child: Text('$n', style: heading(22)),
          );
          final headLine = <Widget>[
            if (count('decision') > 0) ...[
              badge(count('decision'), _rank[0]),
              SizedBox(width: 8 * s),
              Text('件等你决定', style: heading(24)),
            ],
            if (count('decision') > 0 && count('blocked') > 0)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10 * s),
                child: Text('·', style: heading(24)),
              ),
            if (count('blocked') > 0) ...[
              badge(count('blocked'), const Color(0xffff9a4d)),
              SizedBox(width: 8 * s),
              Text('件卡住了', style: heading(24)),
            ],
          ];
          return Padding(
            padding: EdgeInsets.fromLTRB(
              size.maxWidth * .04,
              size.maxHeight * .04,
              size.maxWidth * .04,
              size.maxHeight * .06,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Transform.rotate(
                      angle: -.015,
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16 * s,
                          vertical: 4 * s,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xffffd441),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xffff8cc2),
                              offset: Offset(4 * s, 4 * s),
                            ),
                          ],
                        ),
                        child: Text('现在需要你', style: heading(30)),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: headLine,
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12 * s,
                        vertical: 5 * s,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10 * s),
                        border: Border.all(color: ink, width: 2.5 * s),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.smartphone, size: 18 * s, color: ink),
                          SizedBox(width: 6 * s),
                          Text('在手机上处理', style: body(14)),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 14 * s),
                if (items.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text('现在没有需要你处理的事', style: heading(28)),
                    ),
                  )
                else ...[
                  for (var n = 0; n < 3; n++)
                    Expanded(
                      child: n < items.length
                          ? Padding(
                              padding: EdgeInsets.only(bottom: 14 * s),
                              child: _TvRow(
                                item: items[n],
                                color: _rank[n],
                                s: s,
                                heading: heading,
                                body: body,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
                if (caption.isNotEmpty || mood.isNotEmpty)
                  AgentTvCaption(
                    caption: caption,
                    mood: mood,
                    s: s,
                    heading: heading,
                    body: body,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TvRow extends StatelessWidget {
  const _TvRow({
    required this.item,
    required this.color,
    required this.s,
    required this.heading,
    required this.body,
  });
  final Map<String, Object?> item;
  final Color color;
  final double s;
  final TextStyle Function(double, [Color]) heading, body;

  @override
  Widget build(BuildContext context) {
    final channel = '${item['channel'] ?? ''}';
    final first = item['urgent'] == true;
    final meta = [
      if (channel.isNotEmpty) '#$channel',
      '${item['reason'] ?? ''}',
    ].where((e) => e.isNotEmpty).join(' · ');
    final idle = item['idle'] == true;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16 * s),
        border: Border.all(color: AgentTvAttention.ink, width: 3 * s),
        boxShadow: [BoxShadow(color: color, offset: Offset(0, 7 * s))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16 * s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 78 * s,
              color: color,
              alignment: Alignment.center,
              child: Text('${item['rank']}', style: heading(46)),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 18 * s),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (first) ...[
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8 * s,
                              vertical: 1 * s,
                            ),
                            decoration: BoxDecoration(
                              color: AgentTvAttention.ink,
                              borderRadius: BorderRadius.circular(6 * s),
                            ),
                            child: Text('最急', style: body(12, Colors.white)),
                          ),
                          SizedBox(width: 10 * s),
                        ],
                        Flexible(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: body(12, const Color(0xff6b6660)),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 3 * s),
                    Text(
                      '${item['headline'] ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: heading(22),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: 150 * s,
              color: AgentTvAttention._cream,
              alignment: Alignment.center,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    idle ? '没动' : '已等',
                    style: body(12, const Color(0xff57524c)),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('${item['waitValue']}', style: heading(34)),
                      SizedBox(width: 4 * s),
                      Text('${item['waitUnit']}', style: body(14)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The caption strip at the foot of every TV screen: what the agent says and
/// its mood, as on the phone.
class AgentTvCaption extends StatelessWidget {
  const AgentTvCaption({
    super.key,
    required this.caption,
    required this.mood,
    required this.s,
    required this.heading,
    required this.body,
  });
  final String caption, mood;
  final double s;
  final TextStyle Function(double, [Color]) heading, body;

  @override
  Widget build(BuildContext context) {
    const ink = AgentTvAttention.ink;
    return Container(
      height: 64 * s,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18 * s),
        border: Border.all(color: AgentTvAttention.ink, width: 3 * s),
        boxShadow: [
          BoxShadow(
            color: AgentTvAttention._rank[1],
            offset: Offset(6 * s, 6 * s),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 80 * s,
            decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              'AGENT',
              style: body(9, Colors.white).copyWith(letterSpacing: 1.5 * s),
            ),
          ),
          SizedBox(width: 14 * s),
          Expanded(
            child: Text(
              caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: heading(20),
            ),
          ),
          if (mood.isNotEmpty) ...[
            SizedBox(width: 12 * s),
            Container(
              width: 52 * s,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AgentTvAttention._cream,
                shape: BoxShape.circle,
                border: Border.all(color: ink, width: 3 * s),
              ),
              child: Text(
                mood,
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: 30 * s, height: 1.15),
              ),
            ),
          ],
          SizedBox(width: 16 * s),
        ],
      ),
    );
  }
}

/// Any layer other than the attention list, on the TV: the same dark
/// 10-foot style, a few rows at a time, keeping the row the agent points at
/// on screen. Items are numbered as the agent numbers them (`layer#n`).
class AgentTvLayer extends StatelessWidget {
  const AgentTvLayer({
    super.key,
    required this.frame,
    required this.caption,
    required this.mood,
    this.focused,
  });
  final Map<String, Object?> frame;
  final String caption, mood;

  /// The spotlit item, `layer#n`.
  final String? focused;

  static const _priorityColors = {
    'decision': Color(0xffff5a69),
    'blocked': Color(0xffff9a4d),
    'mention': Color(0xffff8cc2),
    'progress': Color(0xff7fe0a6),
  };

  /// Rows that fit at 10-foot type.
  static const rows = 5;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    const ink = AgentTvAttention.ink;
    final id = '${frame['id'] ?? ''}';
    // Sections head the rows after them; numbered items count from 1.
    final entries = <({String? section, Map<String, Object?> item, int n})>[];
    String? section;
    var n = 0;
    for (final i in (frame['items'] as List?) ?? const []) {
      if (i is! Map) continue;
      final item = Map<String, Object?>.from(i);
      if (item['kind'] == 'section') {
        // A section that only repeats the title says nothing.
        final text = '${item['text'] ?? ''}';
        section = text == '${frame['title'] ?? ''}' ? null : text;
        continue;
      }
      entries.add((section: section, item: item, n: ++n));
      section = null;
    }
    final focus = focused != null && focused!.startsWith('$id#')
        ? int.tryParse(focused!.substring(id.length + 1))
        : null;
    // The page that holds the focused row; the first page otherwise.
    final start = focus == null || focus <= rows
        ? 0
        : ((focus - 1) ~/ rows) * rows;
    final page = entries.skip(start).take(rows).toList();
    final more = entries.length - start - page.length;
    final summary = '${frame['summary'] ?? ''}';
    return AgentCanvas(
      child: LayoutBuilder(
        builder: (context, size) {
          final s = (size.maxHeight / 540).clamp(1.0, 3.0);
          TextStyle heading(double v, [Color color = ink]) => t
              .heading(v * s, weight: FontWeight.w900)
              .copyWith(color: color, height: 1.2);
          TextStyle body(double v, [Color color = ink]) => t
              .body(v * s, weight: FontWeight.w800, color: color)
              .copyWith(height: 1.2);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              size.maxWidth * .04,
              size.maxHeight * .04,
              size.maxWidth * .04,
              size.maxHeight * .06,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Transform.rotate(
                        angle: -.015,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16 * s,
                            vertical: 4 * s,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xffffd441),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xffff8cc2),
                                offset: Offset(4 * s, 4 * s),
                              ),
                            ],
                          ),
                          child: Text(
                            '${frame['title'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: heading(30),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 20 * s),
                    if (entries.length > rows)
                      Text(
                        '${start + 1}–${start + page.length} / ${entries.length}',
                        style: body(14, const Color(0xff57524c)),
                      ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  SizedBox(height: 10 * s),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: body(16),
                  ),
                ],
                SizedBox(height: 14 * s),
                Expanded(
                  child: frame['loading'] == true && entries.isEmpty
                      ? Center(child: Text('正在读取…', style: heading(28)))
                      : Column(
                          children: [
                            for (var r = 0; r < rows; r++)
                              Expanded(
                                child: r < page.length
                                    ? Padding(
                                        padding: EdgeInsets.only(
                                          bottom: 10 * s,
                                        ),
                                        child: AgentFocusable(
                                          id: '$id#${page[r].n}',
                                          child: _TvItemRow(
                                            entry: page[r],
                                            color:
                                                _priorityColors[page[r]
                                                    .item['priority']] ??
                                                _priorityColors['progress']!,
                                            s: s,
                                            heading: heading,
                                            body: body,
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                          ],
                        ),
                ),
                if (more > 0)
                  Padding(
                    padding: EdgeInsets.only(bottom: 10 * s),
                    child: Text(
                      '还有 $more 项，说“下一批”',
                      textAlign: TextAlign.center,
                      style: body(14, const Color(0xff57524c)),
                    ),
                  ),
                if (caption.isNotEmpty || mood.isNotEmpty)
                  AgentTvCaption(
                    caption: caption,
                    mood: mood,
                    s: s,
                    heading: heading,
                    body: body,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TvItemRow extends StatelessWidget {
  const _TvItemRow({
    required this.entry,
    required this.color,
    required this.s,
    required this.heading,
    required this.body,
  });
  final ({String? section, Map<String, Object?> item, int n}) entry;
  final Color color;
  final double s;
  final TextStyle Function(double, [Color]) heading, body;

  @override
  Widget build(BuildContext context) {
    final i = entry.item;
    final message = i['kind'] == 'message';
    final label = '${i['label'] ?? ''}';
    final meta = [
      ?entry.section,
      if (message) '${i['sender'] ?? ''}' else label,
      if (message) '${i['time'] ?? ''}',
    ].where((e) => e.isNotEmpty).join(' · ');
    final title = message ? '${i['text'] ?? ''}' : '${i['title'] ?? ''}';
    final detail = message || i['detail'] == label
        ? ''
        : '${i['detail'] ?? ''}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16 * s),
        border: Border.all(color: AgentTvAttention.ink, width: 3 * s),
        boxShadow: [BoxShadow(color: color, offset: Offset(0, 6 * s))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16 * s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 64 * s,
              color: color,
              alignment: Alignment.center,
              child: Text('${entry.n}', style: heading(34)),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 18 * s),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: body(12, const Color(0xff6b6660)),
                      ),
                    AgentMarkText(
                      title,
                      maxLines: message ? 2 : 1,
                      style: heading(22),
                    ),
                    if (detail.isNotEmpty)
                      AgentMarkText(
                        detail,
                        maxLines: 1,
                        style: body(13, const Color(0xff57524c)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
