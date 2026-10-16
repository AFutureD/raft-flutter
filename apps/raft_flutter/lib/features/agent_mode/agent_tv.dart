import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_attention.dart';
import 'agent_catalog.dart';
import 'agent_frame_view.dart';
import 'agent_mode_data.dart';
import 'agent_surface.dart';

/// Phone side of agent mode on an external display (Android presentation
/// display). The phone keeps input; the TV mirrors the layer stack.
class AgentPresentation {
  AgentPresentation._();
  static final instance = AgentPresentation._();
  static const _channel = MethodChannel('app.raft/agent-presentation');

  int? _shown;
  VoidCallback? onDisplaysChanged;

  /// The offline demo and tests: frames go here instead of to a display.
  ValueChanged<Map<String, Object?>>? debugSink;

  /// Shows agent mode on the first presentation display, if any.
  Future<bool> attach() async {
    if (debugSink != null) {
      _shown = -1;
      return true;
    }
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
    final sink = debugSink;
    if (sink != null) {
      // What the platform channel would hand over: plain JSON.
      sink(jsonDecode(jsonEncode(frame)) as Map<String, Object?>);
      return;
    }
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
    final demo = _shown == -1;
    _shown = null;
    if (demo) return;
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
  final _frames = ValueNotifier<Map<String, Object?>?>(null);

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'frame' && call.arguments is Map) {
        _frames.value = Map<String, Object?>.from(call.arguments as Map);
      }
    });
    unawaited(
      _channel.invokeMethod<Object?>('ready').then((latest) {
        if (latest is Map && mounted) {
          _frames.value = Map<String, Object?>.from(latest);
        }
      }, onError: (_) {}),
    );
  }

  @override
  void dispose() {
    _frames.dispose();
    super.dispose();
  }

  ThemeData _theme(String? id) => switch (id) {
    'elegant-light' => raftTheme(RaftFamily.elegant),
    'elegant-dark' => raftTheme(RaftFamily.elegant, dark: true),
    _ => raftTheme(RaftFamily.brutal),
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _frames,
    builder: (context, f, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(f?['theme'] as String?),
      home: Scaffold(body: AgentTvView(frames: _frames)),
    ),
  );
}

/// The TV's screen, fed by [frames]: applies each frame from the phone,
/// including what is lifted and marked, and draws it as [AgentTvScreen].
/// The app's second engine uses it, and so does the offline demo.
class AgentTvView extends StatefulWidget {
  const AgentTvView({super.key, required this.frames});
  final ValueListenable<Map<String, Object?>?> frames;

  @override
  State<AgentTvView> createState() => _AgentTvViewState();
}

class _AgentTvViewState extends State<AgentTvView> {
  final _spotlight = AgentSpotlightController();
  final _marks = AgentMarkController();

  @override
  void initState() {
    super.initState();
    widget.frames.addListener(_changed);
    _apply(widget.frames.value);
  }

  @override
  void didUpdateWidget(AgentTvView old) {
    super.didUpdateWidget(old);
    if (old.frames != widget.frames) {
      old.frames.removeListener(_changed);
      widget.frames.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.frames.removeListener(_changed);
    _spotlight.dispose();
    _marks.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _apply(widget.frames.value);
    setState(() {});
  }

  /// What is lifted and marked follows the phone.
  void _apply(Map<String, Object?>? next) {
    if (next == null) return;
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
  Widget build(BuildContext context) => AgentTvScreen(
    frame: widget.frames.value,
    spotlight: _spotlight,
    marks: _marks,
  );
}

/// What the TV shows: the front layer of the phone's stack, drawn with the
/// same components, sizes and layout as a desktop window (the TV only shows:
/// its buttons are voice hints), the confirm cards that wait for an answer,
/// and the caption strip with what the agent says and its mood. [frame] is
/// what the phone sends (see `_syncTv` of the page): the layers, each with
/// what it needs to be drawn without a workspace (the attention result, the
/// screen the model composed and the things its cards point at).
class AgentTvScreen extends StatelessWidget {
  const AgentTvScreen({
    super.key,
    required this.frame,
    required this.spotlight,
    required this.marks,
  });
  final Map<String, Object?>? frame;
  final AgentSpotlightController spotlight;
  final AgentMarkController marks;

  /// The front layer's content. The current item (`focused`) is the row that
  /// is highlighted, and the detail slot beside the list shows it.
  static Widget layer(Map<String, Object?> layer, {String? focused}) {
    final id = '${layer['id'] ?? ''}';
    final attention = layer['attention'];
    if (attention is Map) {
      return AgentAttentionView(
        attention: AgentAttention.fromJson(attention.cast<String, Object?>()),
        focusPrefix: id,
        onApprove: (_) {},
        onOpen: (_) {},
        onLater: (_) {},
        batchStart: layer['batch'] as int? ?? 0,
        current: _focusNumber(focused, id),
      );
    }
    final spec = layer['spec'];
    final n = _focusNumber(focused, id);
    // What the phone's layer lists, numbered the way the voice says them.
    final items = [
      for (final i
          in (spec is Map
                      ? agentSurfaceFrame(
                          AgentSurfaceSpec.fromJson(
                            spec.cast<String, Object?>(),
                          ),
                          compact: layer['compact'] == true,
                        )['items']
                      : layer['items'])
                  as List? ??
              const [])
        if (i is Map && i['kind'] != 'section') i.cast<String, Object?>(),
    ];
    final view = spec is Map
        ? _TvSurface(layer: layer)
        : AgentFrameView(frame: layer, focusPrefix: id, focused: focused);
    if (n == null || n < 1 || n > items.length) return view;
    return HfStageScope(
      stage: AgentItemScope(
        id: '$id#$n',
        child: AgentFrameStage(item: items[n - 1], number: n),
      ),
      child: view,
    );
  }

  static int? _focusNumber(String? focused, String id) =>
      focused != null && focused.startsWith('$id#')
      ? int.tryParse(focused.substring(id.length + 1))
      : null;

  /// A confirm card of the phone's tray, without its buttons.
  static Widget confirm(Map<String, Object?> c) {
    final outcome = c['outcome'];
    return HfConfirm(
      message: '${c['title'] ?? ''}',
      changes: [for (final l in (c['changes'] as List? ?? const [])) '$l'],
      risk: c['sensitive'] == true
          ? AgentConfirmRisk.sensitive
          : AgentConfirmRisk.change,
      result: switch (c['result']) {
        'confirmed' => AgentConfirmResult.confirmed,
        'cancelled' => AgentConfirmResult.cancelled,
        _ => null,
      },
      outcome: outcome is Map
          ? AgentActionOutcome(
              kind: AgentOutcomeKind.values.firstWhere(
                (k) => k.name == outcome['kind'],
                orElse: () => AgentOutcomeKind.running,
              ),
              text: '${outcome['text'] ?? ''}',
              undoLabel: outcome['undoLabel'] as String?,
              onUndo: outcome['undo'] == true ? () {} : null,
              onRetry: outcome['retry'] == true ? () {} : null,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = frame;
    final layers = [
      for (final l in (f?['layers'] as List?) ?? const [])
        if (l is Map) Map<String, Object?>.from(l),
    ];
    final top = layers.isEmpty ? null : layers.last;
    final confirms = [
      for (final c in (f?['confirms'] as List?) ?? const [])
        if (c is Map) Map<String, Object?>.from(c),
    ];
    final caption = '${f?['caption'] ?? ''}';
    final mood = '${f?['mood'] ?? ''}';
    return HandsFree(
      surface: HfSurface.tv,
      child: Builder(
        builder: (context) {
          final hf = HandsFree.of(context);
          return AgentMarks(
            controller: marks,
            child: AgentSpotlight(
              controller: spotlight,
              child: HfScreenFrame(
                content: top == null
                    ? Center(
                        child: Text(
                          'Raft · Agent 模式',
                          style: hf.type(HfType.display),
                        ),
                      )
                    : KeyedSubtree(
                        key: ValueKey(top['id']),
                        child: layer(top, focused: f?['spotlight'] as String?),
                      ),
                above: confirms.isEmpty
                    ? null
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final c in confirms)
                            Padding(
                              padding: EdgeInsets.only(top: hf.sp(6)),
                              child: confirm(c),
                            ),
                        ],
                      ),
                caption: caption.isEmpty && mood.isEmpty
                    ? null
                    : HfCaptionStrip(caption: caption, mood: mood),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A screen the model composed, drawn from its frame: the screen, and an
/// entity resolver that answers from what the frame carried.
class _TvSurface extends StatefulWidget {
  const _TvSurface({required this.layer});
  final Map<String, Object?> layer;

  @override
  State<_TvSurface> createState() => _TvSurfaceState();
}

class _TvSurfaceState extends State<_TvSurface> {
  late AgentStaticEntityResolver _resolver;

  @override
  void initState() {
    super.initState();
    _resolver = AgentStaticEntityResolver.fromJson(widget.layer['entities']);
  }

  @override
  void didUpdateWidget(_TvSurface old) {
    super.didUpdateWidget(old);
    if ('${old.layer['entities']}' != '${widget.layer['entities']}') {
      _resolver.dispose();
      _resolver = AgentStaticEntityResolver.fromJson(widget.layer['entities']);
    }
  }

  @override
  void dispose() {
    _resolver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layer = widget.layer;
    return AgentEntityScope(
      resolver: _resolver,
      child: AgentSurfaceView(
        spec: AgentSurfaceSpec.fromJson(
          (layer['spec'] as Map).cast<String, Object?>(),
        ),
        focusPrefix: '${layer['id'] ?? ''}',
        compact: layer['compact'] == true,
        expanded: {
          for (final p in (layer['expanded'] as List? ?? const [])) '$p',
        },
      ),
    );
  }
}
