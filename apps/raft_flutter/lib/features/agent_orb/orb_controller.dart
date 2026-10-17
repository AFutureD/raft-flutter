import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart'
    show AgentMicState, AgentSpeaker;
import 'package:raft_ui/raft_ui.dart';

import '../../data/workspace_controller.dart';
import '../agent_mode/agent_audio.dart';
import '../agent_mode/agent_memory.dart';
import '../agent_mode/agent_summary.dart';
import '../agent_mode/agent_voice.dart';
import '../agent_mode/agent_voice_settings.dart';
import '../agent_mode/voice_provider.dart';
import 'briefing/orb_briefing_models.dart' show OrbBriefItem;
import 'briefing/orb_briefing_tools.dart'
    show defaultOrbOpenLink, orbBriefingTools;
import 'nav/orb_nav_tools.dart' show orbNavigationTools;
import 'orb_arrival_brief.dart';
import 'orb_operating.dart';
import 'orb_prompt.dart';
import 'orb_sheet.dart';
import 'orb_state.dart';
import 'orb_tool.dart';

/// One line of the orb's transcript.
enum OrbEntryKind {
  /// What the person said or typed.
  user,

  /// What the agent said.
  agent,

  /// What a tool did ("已打开 #raft-flutter").
  activity,

  /// The app talking about itself (no key, a connection error).
  notice,
}

class OrbEntry {
  OrbEntry(this.kind, this.text);
  final OrbEntryKind kind;
  String text;
}

/// The orb's session: one conversation with the model (voice through
/// [AgentVoiceController], typed text through the same session), the tool
/// registry, the transcript and the sheet.
///
/// The model and provider, keys, voice and reasoning effort are the Agent mode
/// settings ([AgentVoiceSettings]); a session summary goes to the shared
/// agent's DM like Agent mode's (when that is set up).
class OrbController extends ChangeNotifier {
  OrbController({
    required this.workspace,
    required this.navigatorContext,
    List<OrbTool>? appTools,
    VoiceSessionFactory? sessionFactory,
    AgentAudio? audio,
    AgentVoiceKey? voiceKey,
    this.operatingLinger = const Duration(milliseconds: 2500),
  }) {
    final all = [
      ..._shellTools(),
      ...?appTools,
      if (appTools == null)
        ...orbNavigationTools(arrivalBrief: orbArrivalBrief()),
      if (appTools == null) ...orbBriefingTools(openLink: openBriefItem),
    ];
    tools = {for (final tool in all) tool.name: tool};
    voice = AgentVoiceController(
      tools: [for (final tool in tools.values) tool.declaration],
      onToolCall: dispatch,
      systemPrompt: _systemPrompt,
      beforeConnect: _loadBrain,
      onSessionEnd: _sessionEnded,
      onUserSaid: _userSaid,
      onModelSpoke: _modelSpoke,
      onModelTurnComplete: _modelTurnComplete,
      onModelInterrupted: _modelInterrupted,
      audio: audio,
      key: voiceKey,
      sessionFactory: sessionFactory,
    )..addListener(notifyListeners);
    voice.saying.addListener(_sayingChanged);
    operating.addListener(_operatingChanged);
  }

  final WorkspaceController workspace;

  /// A context under the app's Navigator (null before it exists).
  final BuildContext? Function() navigatorContext;

  /// How long "Agent is operating" stays after the model's turn ends.
  final Duration operatingLinger;

  /// The voice session (also the typed text path).
  late final AgentVoiceController voice;

  /// The tool registry: shell tools, then navigation, then briefing tools.
  late final Map<String, OrbTool> tools;

  /// "Agent is operating": set by tools, cleared by the user's touch.
  final operating = OrbOperating();

  final _entries = <OrbEntry>[];
  static const _maxEntries = 80;

  /// The transcript, oldest first.
  List<OrbEntry> get entries => List.unmodifiable(_entries);

  bool _modelSpeaking = false;
  bool _disposed = false;
  Timer? _linger;
  String? _brainContext;

  /// A short status for the person (no key, no microphone), or null.
  String? get notice => voice.notice;

  /// Whether a call is on: connecting, listening or the model speaking. A tap
  /// on the orb hangs up.
  bool get inCall =>
      voice.live ||
      const {
        AgentMicState.connecting,
        AgentMicState.holding,
        AgentMicState.live,
        AgentMicState.speaking,
      }.contains(voice.state);

  bool get connecting => voice.state == AgentMicState.connecting;

  /// What the orb shows.
  OrbState get state {
    if (operating.value) return OrbState.operating;
    if (_modelSpeaking || voice.state == AgentMicState.speaking) {
      return OrbState.speaking;
    }
    return switch (voice.state) {
      AgentMicState.idle => OrbState.idle,
      AgentMicState.connecting || AgentMicState.thinking => OrbState.thinking,
      AgentMicState.holding || AgentMicState.live => OrbState.listening,
      AgentMicState.speaking => OrbState.speaking,
    };
  }

  /// What the person is saying right now (for the pill by the orb): the last
  /// line of the transcript while the mic is open and it is theirs.
  String? get listeningText {
    if (state != OrbState.listening || _entries.isEmpty) return null;
    final last = _entries.last;
    return last.kind == OrbEntryKind.user ? last.text : null;
  }

  // ---- gestures -----------------------------------------------------------

  /// A tap on the orb: hang up when a call is on, else open the sheet.
  Future<void> tapOrb() async {
    if (inCall) {
      await hangUp();
      return;
    }
    if (sheetOpen) return;
    await openSheet();
  }

  /// A long-press on the orb: start a live voice conversation.
  Future<void> longPressOrb() async {
    if (inCall) return;
    if (!await voice.hasKey) {
      _note('还没有语音 Key：在 设置 > Labs 里扫码填入（和 Agent 模式共用）');
      await openSheet();
      return;
    }
    // Down and up at once: a call that stays live until a tap hangs it up.
    unawaited(voice.micDown());
    voice.micUp(Duration.zero);
  }

  /// Ends the call at once; the sheet stays as it is.
  Future<void> hangUp() async {
    _modelSpeaking = false;
    operating.takeOver();
    await voice.restart();
    notifyListeners();
  }

  // ---- text ---------------------------------------------------------------

  /// A typed turn, through the same session as the voice.
  Future<void> sendText(String text) async {
    final said = text.trim();
    if (said.isEmpty) return;
    _agentOpen = false;
    _add(OrbEntryKind.user, said);
    final sent = await voice.sendText(said);
    if (!sent) _note('还没有语音 Key：在 设置 > Labs 里扫码填入（和 Agent 模式共用）');
  }

  // ---- transcript ---------------------------------------------------------

  bool _agentOpen = false;
  String _saying = '';

  void _add(OrbEntryKind kind, String text) {
    _entries.add(OrbEntry(kind, text));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void _note(String text) {
    _agentOpen = false;
    _add(OrbEntryKind.notice, text);
  }

  void _userSaid(String text, {required bool fresh}) {
    _agentOpen = false;
    final last = _entries.isEmpty ? null : _entries.last;
    if (!fresh && last != null && last.kind == OrbEntryKind.user) {
      last.text += text;
      notifyListeners();
    } else {
      _add(OrbEntryKind.user, text.trimLeft());
    }
  }

  /// What the agent says arrives in `voice.saying`, chunk by chunk.
  void _sayingChanged() {
    final now = voice.saying.value;
    if (now.isEmpty) {
      _saying = '';
      _agentOpen = false;
      return;
    }
    final delta = now.startsWith(_saying) ? now.substring(_saying.length) : now;
    _saying = now;
    if (delta.isEmpty) return;
    final last = _entries.isEmpty ? null : _entries.last;
    if (_agentOpen && last != null && last.kind == OrbEntryKind.agent) {
      last.text += delta;
      notifyListeners();
    } else {
      _agentOpen = true;
      _add(OrbEntryKind.agent, delta.trimLeft());
    }
  }

  void _modelSpoke() {
    if (_modelSpeaking) return;
    _modelSpeaking = true;
    notifyListeners();
  }

  void _modelTurnComplete() {
    _agentOpen = false;
    _saying = '';
    if (_modelSpeaking) {
      _modelSpeaking = false;
      notifyListeners();
    }
    // The screen is the user's again shortly after the agent is done.
    if (operating.value) {
      _linger?.cancel();
      _linger = Timer(operatingLinger, () {
        if (!_disposed) operating.value = false;
      });
    }
  }

  void _modelInterrupted() {
    _agentOpen = false;
    _modelSpeaking = false;
    notifyListeners();
  }

  void _operatingChanged() {
    if (operating.value) _linger?.cancel();
    notifyListeners();
  }

  // ---- tools --------------------------------------------------------------

  /// Runs the tool the model called and returns its result for the model.
  Future<Map<String, Object?>> dispatch(
    String name,
    Map<String, Object?> args,
  ) async {
    final tool = tools[name];
    if (tool == null) return {'error': '没有这个工具：$name'};
    final context = navigatorContext();
    if (context == null || !context.mounted) {
      return {'error': '界面还没准备好，稍后再试'};
    }
    // The toast names what was opened; a tool may say it better.
    if (!operating.value) operating.label = _labelOf(args);
    // A tool that moves the app holds `operating` while it does or changes
    // the location: the sheet then steps aside to show the page.
    var movedScreen = false;
    void watch() {
      if (operating.value) movedScreen = true;
    }

    final before = workspace.location.toString();
    operating.addListener(watch);
    Map<String, Object?> result;
    try {
      result = await tool.handler(
        args,
        OrbToolContext(
          workspace: workspace,
          navigatorContext: context,
          operating: operating,
        ),
      );
    } catch (_) {
      result = {'error': '工具出错：$name'};
    } finally {
      operating.removeListener(watch);
    }
    final failed =
        result['error'] != null ||
        result['cancelled'] == true ||
        result['candidates'] != null;
    if (!failed &&
        !_disposed &&
        (movedScreen || workspace.location.toString() != before)) {
      unawaited(peekSheet());
    }
    final line = _activityLine(name, result);
    if (line != null && !_disposed) {
      _agentOpen = false;
      _add(OrbEntryKind.activity, line);
    }
    return result;
  }

  /// An item of the briefing card was tapped: the app goes there, and the
  /// sheet steps aside so the page shows.
  @visibleForTesting
  void openBriefItem(OrbBriefItem item, OrbToolContext ctx) {
    defaultOrbOpenLink(item, ctx);
    unawaited(peekSheet());
  }

  static String? _labelOf(Map<String, Object?> args) {
    for (final key in const ['target', 'name', 'title']) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// The activity line of a tool result: its own `activity` text, else what
  /// the tool is known for.
  static String? _activityLine(String name, Map<String, Object?> result) {
    if (name == 'show_orb_sheet' || name == 'hide_orb_sheet') return null;
    final own = result['activity'];
    if (own is String && own.trim().isNotEmpty) return own.trim();
    if (result['cancelled'] == true) return '已停下：你接管了屏幕';
    final error = result['error'];
    if (error != null) return '$name 没成功：${_clip('$error', 60)}';
    final title = result['title'];
    return switch (name) {
      'navigate' =>
        title is String && title.isNotEmpty ? '已打开 $title' : '已打开页面',
      'describe_page' => '已查看当前页面',
      'read_conversation' => '已读取对话',
      'get_briefing' => '已准备简报',
      _ => '已调用 $name',
    };
  }

  static String _clip(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  List<OrbTool> _shellTools() => [
    OrbTool(
      declaration: const {
        'name': 'show_orb_sheet',
        'description': '打开悬浮球的对话面板（看对话记录、打字）。用户说“打开面板”“看看记录”时用。立即生效。',
      },
      handler: (args, ctx) async => {'ok': await openSheet()},
    ),
    OrbTool(
      declaration: const {
        'name': 'hide_orb_sheet',
        'description': '收起悬浮球的对话面板，回到页面。用户说“收起来”“关掉面板”时用。立即生效。',
      },
      handler: (args, ctx) async {
        closeSheet();
        return {'ok': true};
      },
    ),
  ];

  // ---- the sheet ----------------------------------------------------------

  RaftPresentedRoute<void>? _sheetRoute;
  bool _orbTouch = false;

  /// Moves the open sheet between its detents: lowered to a peek when a tool
  /// changed the screen, raised again by the person.
  final detents = RaftSheetDetents(peekSize: .3);

  bool get sheetOpen => _sheetRoute != null;

  /// Opens the orb sheet (the transcript and the text input). False when the
  /// app has no Navigator yet.
  Future<bool> openSheet() async {
    if (_sheetRoute != null) return true;
    final context = navigatorContext();
    if (context == null || !context.mounted) return false;
    final route = raftPresentedRoute<void>(
      context,
      policy: _sheetPolicy,
      sheetInitialSize: .65,
      sheetDetents: detents,
      label: 'Agent',
      content: (context, form) => OrbSheet(controller: this),
    );
    _sheetRoute = route;
    notifyListeners();
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (identical(_sheetRoute, route) && !_disposed) {
          _sheetRoute = null;
          notifyListeners();
        }
      }),
    );
    return true;
  }

  /// Lowers the sheet to a small peek (the last of the transcript and the
  /// input) so the page the agent opened shows; the keyboard goes down with
  /// it. Nothing when the sheet is not open.
  Future<void> peekSheet() async {
    if (_sheetRoute == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    await detents.peek();
  }

  /// Raises a peeking sheet to the size it opens at (the person tapped the
  /// transcript or the input).
  Future<void> expandSheet() async {
    if (_sheetRoute == null || !detents.peeking) return;
    await detents.restore();
  }

  /// Whether the sheet is lowered to the peek.
  bool get sheetPeeking => _sheetRoute != null && detents.peeking;

  /// Closes the orb sheet, if it is open.
  void closeSheet() {
    final route = _sheetRoute;
    if (route == null) return;
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  /// The orb's sheet is a sheet on every phone width.
  static const _sheetPolicy = RaftPresentationPolicy(
    compact: RaftSurfaceForm.sheet,
    medium: RaftSurfaceForm.sheet,
    wide: RaftSurfaceForm.sheet,
  );

  // ---- touches ------------------------------------------------------------

  /// A pointer went down on the orb's own surface (the sheet): not the app.
  void markOrbTouch() => _orbTouch = true;

  /// A pointer went down on the app content. Takes the screen back from the
  /// agent, unless the touch was on the orb's sheet.
  void appTouched() {
    if (_orbTouch) {
      _orbTouch = false;
      return;
    }
    operating.takeOver();
  }

  // ---- model --------------------------------------------------------------

  String _systemPrompt() => orbSystemPrompt(
    style: AgentVoiceSettings.instance.styleNote,
    memory: _brainContext,
    channels: workspace.channels
        .where((c) => c.name.isNotEmpty)
        .take(80)
        .map((c) => c.name)
        .join('、'),
  );

  /// The shared agent's memory, as Agent mode reads it, before a session.
  Future<void> _loadBrain() async {
    final settings = AgentVoiceSettings.instance;
    try {
      final brain = AgentBrain(workspace);
      final chosen = await brain.liveBrain(settings);
      _brainContext = chosen == null ? null : await brain.context(chosen);
    } catch (_) {
      _brainContext = null;
    }
  }

  /// A summary of the session goes to the shared agent, like Agent mode.
  void _sessionEnded(
    List<(AgentSpeaker, String)> transcript,
    List<AgentToolOutcome> outcomes,
  ) {
    final settings = AgentVoiceSettings.instance;
    final brain = settings.brain;
    if (brain == null || !settings.writeBack) return;
    unawaited(
      AgentBrain(workspace)
          .sendSummary(brain, transcript, outcomes)
          .catchError((Object _) => false),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _linger?.cancel();
    operating.removeListener(_operatingChanged);
    voice.saying.removeListener(_sayingChanged);
    voice.removeListener(notifyListeners);
    voice.dispose();
    operating.dispose();
    super.dispose();
  }
}
