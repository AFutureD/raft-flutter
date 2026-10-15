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

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'frame' && call.arguments is Map) {
        setState(
          () => frame = Map<String, Object?>.from(call.arguments as Map),
        );
      }
    });
    unawaited(
      _channel.invokeMethod<Object?>('ready').then((latest) {
        if (latest is Map && mounted) {
          setState(() => frame = Map<String, Object?>.from(latest));
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
          return Scaffold(
            backgroundColor: t.canvas,
            body: LayoutBuilder(
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
                        : ZLayerStack(
                            padding: EdgeInsets.only(top: 34 * scale),
                            layers: [
                              for (final l in layers)
                                ZLayer(
                                  key: ValueKey(l['id']),
                                  peek: '${l['peek'] ?? ''}',
                                  child: AgentFrameView(frame: l),
                                ),
                            ],
                          ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// Renders one serialized layer (see [agentLayerFrame]).
class AgentFrameView extends StatelessWidget {
  const AgentFrameView({super.key, required this.frame, this.onOpen});
  final Map<String, Object?> frame;

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
            'message' => AgentMessageTile(
              sender: '${i['sender'] ?? ''}',
              time: i['time'] as String?,
              text: '${i['text'] ?? ''}',
            ),
            _ => AgentPriorityCard(
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
          },
      ],
    );
  }
}
