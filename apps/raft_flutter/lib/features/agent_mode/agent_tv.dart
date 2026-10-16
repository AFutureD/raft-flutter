import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

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
              backgroundColor: AgentTvAttention.ink,
              body: AgentTvAttention(
                frame: Map<String, Object?>.from(top['tv'] as Map),
              ),
            );
          }
          return Scaffold(
            backgroundColor: t.canvas,
            body: AgentCanvas(
              child: LayoutBuilder(
                builder: (context, size) {
                  // 10-foot type: scale with the display, keep a 6% bottom safe
                  // area for launchers that draw a taskbar over presentations.
                  final scale = (size.maxHeight / 540).clamp(1.0, 3.0);
                  return MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        size.maxWidth * .05,
                        size.maxHeight * .04,
                        size.maxWidth * .05,
                        size.maxHeight * .06,
                      ),
                      child: layers.isEmpty
                          ? Center(
                              child: Text(
                                'Raft · Agent 模式',
                                style: t.heading(28),
                              ),
                            )
                          : AgentMarks(
                              controller: _marks,
                              child: AgentSpotlight(
                                controller: _spotlight,
                                child: ZLayerStack(
                                  padding: EdgeInsets.only(top: 34 * scale),
                                  layers: [
                                    for (final l in layers)
                                      ZLayer(
                                        key: ValueKey(l['id']),
                                        peek: '${l['peek'] ?? ''}',
                                        child: AgentFrameView(
                                          frame: l,
                                          focusPrefix: '${l['id']}',
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  );
                },
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
          : AgentFocusable(id: '$prefix#$n', child: child);
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
  static const _rank = [Color(0xffff5a69), Color(0xff2ccbf0), Color(0xffffd441)];

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return ColoredBox(
      color: ink,
      child: LayoutBuilder(
        builder: (context, size) {
          // 10-foot type: 22 logical px of headline per 540 px of height,
          // never below the phone sizes.
          final s = (size.maxHeight / 540).clamp(1.0, 3.0);
          TextStyle heading(double v, [Color color = ink]) =>
              t.heading(v * s, weight: FontWeight.w900).copyWith(color: color, height: 1.2);
          TextStyle body(double v, [Color color = ink]) =>
              t.body(v * s, weight: FontWeight.w800, color: color).copyWith(height: 1.2);
          final items = [
            for (final i in (frame['items'] as List?) ?? const [])
              if (i is Map) Map<String, Object?>.from(i),
          ];
          int count(String k) => (frame[k] as int?) ?? 0;
          final caption = '${frame['caption'] ?? ''}';
          Widget badge(int n, Color color) => Container(
            padding: EdgeInsets.symmetric(horizontal: 8 * s),
            constraints: BoxConstraints(minWidth: 34 * s),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(9 * s),
              border: Border.all(color: Colors.white, width: 2.5 * s),
            ),
            child: Text('$n', style: heading(22)),
          );
          final headLine = <Widget>[
            if (count('decision') > 0) ...[
              badge(count('decision'), _rank[0]),
              SizedBox(width: 8 * s),
              Text('件等你决定', style: heading(24, Colors.white)),
            ],
            if (count('decision') > 0 && count('blocked') > 0)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10 * s),
                child: Text('·', style: heading(24, Colors.white)),
              ),
            if (count('blocked') > 0) ...[
              badge(count('blocked'), const Color(0xffff9a4d)),
              SizedBox(width: 8 * s),
              Text('件卡住了', style: heading(24, Colors.white)),
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
                        borderRadius: BorderRadius.circular(10 * s),
                        border: Border.all(
                          color: const Color(0xffffd441),
                          width: 2 * s,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.smartphone,
                            size: 18 * s,
                            color: const Color(0xffffd441),
                          ),
                          SizedBox(width: 6 * s),
                          Text(
                            '在手机上处理',
                            style: body(14, const Color(0xffffd441)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 14 * s),
                if (items.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        '现在没有需要你处理的事',
                        style: heading(28, Colors.white),
                      ),
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
                if (caption.isNotEmpty)
                  Container(
                    height: 64 * s,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18 * s),
                      boxShadow: [
                        BoxShadow(
                          color: _rank[1],
                          offset: Offset(6 * s, 6 * s),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 80 * s,
                          decoration: const BoxDecoration(
                            color: ink,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'AGENT',
                            style: body(9, Colors.white).copyWith(
                              letterSpacing: 1.5 * s,
                            ),
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
                        SizedBox(width: 16 * s),
                      ],
                    ),
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
