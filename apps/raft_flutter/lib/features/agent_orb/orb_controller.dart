import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart'
    show AgentMicState, AgentSpeaker;

import '../../data/workspace_controller.dart';
import '../agent_mode/agent_audio.dart';
import '../agent_mode/agent_live_guard.dart' show agentLiveIdleLimit;
import '../agent_mode/agent_memory.dart';
import '../agent_mode/agent_summary.dart';
import '../agent_mode/agent_voice.dart';
import '../agent_mode/agent_voice_settings.dart';
import '../agent_mode/voice_provider.dart';
import 'briefing/orb_briefing_models.dart'
    show OrbBriefItem, OrbBriefScope, OrbBriefing;
import 'briefing/orb_briefing_service.dart';
import 'briefing/orb_briefing_tools.dart'
    show defaultOrbOpenLink, orbBriefingTools;
import 'nav/orb_nav_tools.dart'
    show orbChannelsLine, orbDirectoryOf, orbNavigationTools;
import 'orb_arrival_brief.dart';
import 'orb_operating.dart';
import 'orb_prompt.dart';
import 'orb_layer.dart';
import 'orb_state.dart';
import 'orb_summary.dart';
import 'orb_tool.dart';

/// Sends the summary of a session to the shared agent (the orb's header on
/// it); tests give a fake.
typedef OrbSummarySender = Future<bool> Function(
  AgentBrainChoice brain,
  List<(AgentSpeaker, String)> transcript,
  List<AgentToolOutcome> outcomes,
  String header,
);

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

/// What the subtitle bubble says: the person's words as they are recognised,
/// then the agent's current line.
class OrbSubtitle {
  const OrbSubtitle(this.text, {required this.agent});
  final String text;
  final bool agent;
}

/// The orb's session: one conversation with the model (voice through
/// [AgentVoiceController], typed text through the same session), the tool
/// registry, the transcript, the call's clock and the immersive layer.
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
    this.summarySender,
    this.operatingLinger = const Duration(milliseconds: 2500),
    this.endedLinger = const Duration(seconds: 3),
    this.subtitleLinger = const Duration(seconds: 2),
    Duration liveIdleLimit = agentLiveIdleLimit,
    DateTime Function()? now,
    Future<void> Function(WorkspaceController w)? warmUp,
  }) : _now = now ?? DateTime.now,
       _warmUp =
           warmUp ??
           (appTools == null
               ? (w) => OrbBriefingService.of(w).warm(OrbBriefScope.activity)
               : null) {
    final all = [
      ..._shellTools(),
      ...?appTools,
      if (appTools == null)
        ...orbNavigationTools(arrivalBrief: orbArrivalBrief()),
      if (appTools == null)
        ...orbBriefingTools(
          showBriefing: (briefing, ctx) => showBriefing(briefing),
        ),
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
      liveIdleLimit: liveIdleLimit,
      audio: audio,
      key: voiceKey,
      sessionFactory: sessionFactory,
    )..addListener(_voiceChanged);
    voice.saying.addListener(_sayingChanged);
    operating.addListener(_operatingChanged);
  }

  final WorkspaceController workspace;

  /// Reads the Activity briefing ahead of time when the person turns to the
  /// orb, so the briefing `navigate` brings is mostly written by then.
  final Future<void> Function(WorkspaceController w)? _warmUp;

  void _warm() {
    final warmUp = _warmUp;
    if (warmUp != null) unawaited(warmUp(workspace).catchError((Object _) {}));
  }

  /// Where a session's summary goes (the shared agent's DM unless a test
  /// gives another).
  final OrbSummarySender? summarySender;

  /// A context under the app's Navigator (null before it exists).
  final BuildContext? Function() navigatorContext;

  /// How long "Agent is operating" stays after the model's turn ends.
  final Duration operatingLinger;

  /// How long the grey "hung up" pill stays after a call.
  final Duration endedLinger;

  /// How long a subtitle stays after its last change.
  final Duration subtitleLinger;

  final DateTime Function() _now;

  /// What the person is typing in the layer's input. It lives as long as the
  /// orb, not the layer: the keyboard going down, the layer closing or being
  /// rebuilt never takes it away.
  final draft = TextEditingController();

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
      AgentMicState.connecting => OrbState.connecting,
      AgentMicState.thinking => OrbState.thinking,
      AgentMicState.holding || AgentMicState.live => OrbState.listening,
      AgentMicState.speaking => OrbState.speaking,
    };
  }

  // ---- the call's clock and the subtitle ------------------------------------

  /// The seconds of the live call, once a second (the pill's timer listens).
  final callSeconds = ValueNotifier<int>(0);

  DateTime? _callStart;
  bool _wasInCall = false;
  bool _hadVoice = false;
  Duration? _endedLength;
  Timer? _tick;
  Timer? _endedTimer;

  /// How long the live call has lasted (zero while it connects).
  Duration get callLength {
    final start = _callStart;
    return start == null ? Duration.zero : _now().difference(start);
  }

  /// The length of the call that was just hung up, for [endedLinger]; null
  /// when no voice call has just ended.
  Duration? get endedCallLength => _endedLength;

  /// The line under the pill, or null once it has faded.
  OrbSubtitle? subtitle;
  Timer? _subtitleTimer;

  void _subtitleIs(String text, {required bool agent}) {
    subtitle = OrbSubtitle(text, agent: agent);
    _subtitleTimer?.cancel();
    _subtitleTimer = Timer(subtitleLinger, () {
      if (_disposed) return;
      subtitle = null;
      notifyListeners();
    });
  }

  void _voiceChanged() {
    _syncCall();
    notifyListeners();
  }

  /// Follows the call: it starts when the voice session is being set up, its
  /// clock runs from the moment it is connected, and when it ends a voice
  /// call leaves its length for a moment.
  void _syncCall() {
    final now = inCall;
    if (now && !_wasInCall) {
      _callStart = null;
      _hadVoice = false;
      _endedLength = null;
      _endedTimer?.cancel();
      callSeconds.value = 0;
    } else if (!now && _wasInCall) {
      _finishCall();
    }
    _wasInCall = now;
    if (!now) return;
    if (voice.live) _hadVoice = true;
    if (_callStart == null && voice.state != AgentMicState.connecting) {
      _callStart = _now();
      callSeconds.value = 0;
      _tick?.cancel();
      // ignore: raft_lints/avoid_unreviewed_idle_work -- Runs once a second only while a connected call is on; cancelled when the call ends or the orb is disposed.
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        callSeconds.value = callLength.inSeconds;
      });
    }
  }

  void _finishCall() {
    _tick?.cancel();
    _tick = null;
    final start = _callStart;
    _callStart = null;
    if (!_hadVoice || start == null) return;
    _endedLength = _now().difference(start);
    _endedTimer?.cancel();
    _endedTimer = Timer(endedLinger, () {
      if (_disposed) return;
      _endedLength = null;
      notifyListeners();
    });
  }

  // ---- gestures -----------------------------------------------------------

  /// A tap on the orb: hang up when a call is on, else open the layer.
  Future<void> tapOrb() async {
    if (inCall) {
      await hangUp();
      return;
    }
    if (layerOpen) return;
    _warm();
    await openLayer();
  }

  /// A long-press on the orb: start a live voice conversation.
  Future<void> longPressOrb() async {
    if (inCall) return;
    _warm();
    if (!await voice.hasKey) {
      _note('还没有语音 Key：在 设置 > Labs 里扫码填入（和 Agent 模式共用）');
      await openLayer();
      return;
    }
    // Down and up at once: a call that stays live until a tap hangs it up.
    unawaited(voice.micDown());
    voice.micUp(Duration.zero);
  }

  /// Ends the call at once; the layer stays as it is.
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
    _subtitleIs(_entries.last.text, agent: false);
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
    _subtitleIs(_entries.last.text, agent: true);
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
    final labelFromArgs = operating.label;
    // A tool that moves the app holds `operating` while it does or changes
    // the location: the layer then steps aside to show the page.
    var movedScreen = false;
    void watch() {
      if (operating.value) movedScreen = true;
    }

    final before = workspace.location.toString();
    operating.addListener(watch);
    Map<String, Object?> result;
    final toolContext = OrbToolContext(
      workspace: workspace,
      navigatorContext: context,
      operating: operating,
    );
    try {
      result = await tool.handler(args, toolContext);
    } catch (_) {
      result = {'error': '工具出错：$name'};
    } finally {
      operating.removeListener(watch);
    }
    // What was opened, in the tool's own words, for the pill.
    final opened = result['title'];
    if (opened is String &&
        opened.trim().isNotEmpty &&
        operating.value &&
        operating.label == labelFromArgs) {
      operating.label = opened.trim();
    }
    final failed =
        result['error'] != null ||
        result['cancelled'] == true ||
        result['candidates'] != null;
    if (!failed &&
        !_disposed &&
        (movedScreen || workspace.location.toString() != before)) {
      collapseLayer();
    }
    // Asked to show what needs the person: the cards over the page it opened.
    final arrived = toolContext.arrived;
    if (!failed && !_disposed && args['show'] == true && arrived != null) {
      showBriefing(arrived);
    }
    final line = _activityLine(name, result);
    if (line != null && !_disposed) {
      _agentOpen = false;
      _add(OrbEntryKind.activity, line);
    }
    return result;
  }

  /// An item of the briefing card was tapped: the app goes there, and the
  /// layer steps aside so the page shows.
  @visibleForTesting
  void openBriefItem(OrbBriefItem item, OrbToolContext ctx) {
    defaultOrbOpenLink(item, ctx);
    collapseLayer();
  }

  /// A card of the briefing in the layer was tapped.
  void openBriefItemTapped(OrbBriefItem item) {
    final context = navigatorContext();
    if (context == null || !context.mounted) return;
    openBriefItem(
      item,
      OrbToolContext(
        workspace: workspace,
        navigatorContext: context,
        operating: operating,
      ),
    );
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
      'list_targets' => '已查看可去的地方',
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
        'description': '打开悬浮球的全屏对话层（看对话记录、打字）。用户说“打开面板”“看看记录”时用。立即生效。',
      },
      handler: (args, ctx) async => {'ok': await openLayer()},
    ),
    OrbTool(
      declaration: const {
        'name': 'hide_orb_sheet',
        'description': '收起悬浮球的全屏对话层，回到页面。用户说“收起来”“关掉面板”时用。立即生效。',
      },
      handler: (args, ctx) async {
        closeLayer();
        return {'ok': true};
      },
    ),
  ];

  // ---- the immersive layer ------------------------------------------------

  OrbLayerRoute? _layerRoute;
  bool _orbTouch = false;

  bool get layerOpen => _layerRoute != null;

  /// The briefing the layer shows as cards (`get_briefing` with `show`),
  /// until the layer closes.
  OrbBriefing? shownBriefing;

  /// Opens the immersive layer (the transcript and the text input). False
  /// when the app has no Navigator yet.
  Future<bool> openLayer() async {
    if (_layerRoute != null) return true;
    final context = navigatorContext();
    if (context == null || !context.mounted) return false;
    // A word left half-composed has no keyboard to finish it now.
    if (draft.value.composing.isValid) {
      draft.value = draft.value.copyWith(composing: TextRange.empty);
    }
    final route = OrbLayerRoute(orb: this);
    _layerRoute = route;
    notifyListeners();
    unawaited(
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (identical(_layerRoute, route) && !_disposed) {
          _layerRoute = null;
          shownBriefing = null;
          notifyListeners();
        }
      }),
    );
    return true;
  }

  /// Shows [briefing] as cards in the layer, opening it when it is closed.
  void showBriefing(OrbBriefing briefing) {
    shownBriefing = briefing;
    notifyListeners();
    unawaited(openLayer());
  }

  /// The layer steps aside so the page the agent opened shows; the keyboard
  /// goes down with it. The call, if one is on, is not touched.
  void collapseLayer() {
    if (_layerRoute == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    closeLayer();
  }

  /// Closes the immersive layer, if it is open. Never hangs up.
  void closeLayer() {
    final route = _layerRoute;
    if (route == null) return;
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  // ---- touches ------------------------------------------------------------

  /// A pointer went down on the orb's own surface (the layer): not the app.
  void markOrbTouch() => _orbTouch = true;

  /// A pointer went down on the app content. Takes the screen back from the
  /// agent, unless the touch was on the orb's layer.
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
    channels: orbChannelsLine(orbDirectoryOf(workspace)),
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
    // A quick "go to X" or a test of the microphone is not worth a DM.
    if (!orbSummaryWorthSending(transcript, outcomes)) return;
    final send =
        summarySender ??
        (brain, transcript, outcomes, header) =>
            AgentBrain(workspace)
                .sendSummary(brain, transcript, outcomes, header: header);
    unawaited(
      send(
        brain,
        transcript,
        outcomes,
        AgentSessionSummary.orbHeader,
      ).catchError((Object _) => false),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _linger?.cancel();
    _tick?.cancel();
    _endedTimer?.cancel();
    _subtitleTimer?.cancel();
    operating.removeListener(_operatingChanged);
    voice.saying.removeListener(_sayingChanged);
    voice.removeListener(_voiceChanged);
    callSeconds.dispose();
    voice.dispose();
    operating.dispose();
    draft.dispose();
    super.dispose();
  }
}
