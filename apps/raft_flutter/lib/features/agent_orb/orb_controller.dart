import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart'
    show AgentMicState, AgentSpeaker;

import '../../data/raft_location.dart' show RaftRoute;
import '../../data/workspace_controller.dart';
import '../agent_mode/agent_audio.dart';
import '../agent_mode/agent_live_guard.dart' show agentLiveIdleLimit;
import '../agent_mode/agent_memory.dart';
import '../agent_mode/agent_steering.dart';
import '../agent_mode/gemini_live.dart' show AgentToolHandler;
import '../agent_mode/key_info.dart' show KeyInfo;
import '../agent_mode/layered_voice.dart' show createLayeredSession;
import '../agent_mode/agent_summary.dart';
import '../agent_mode/agent_voice.dart';
import '../agent_mode/agent_voice_settings.dart';
import '../agent_mode/voice_provider.dart';
import 'actions/orb_actions.dart';
import 'actions/orb_task_tools.dart';
import 'briefing/orb_activity_watch.dart';
import 'briefing/orb_briefing_models.dart'
    show OrbBriefItem, OrbBriefScope, OrbBriefing;
import 'briefing/orb_briefing_service.dart';
import 'briefing/orb_briefing_tools.dart'
    show defaultOrbOpenLink, orbBriefingTools;
import 'nav/orb_nav_tools.dart'
    show orbChannelsLine, orbDirectoryOf, orbNavigationTools;
import 'nav/orb_page_description.dart' show orbPageTitle;
import 'actions/orb_card_words.dart' show orbPlainNo, orbPlainYes;
import 'actions/orb_reply.dart' show OrbReplyContext;
import 'actions/orb_reply_content.dart';
import 'orb_agent_review.dart';
import 'orb_arrival_brief.dart';
import 'orb_driving_queue.dart';
import 'orb_driving.dart' show orbSayHint;
import 'orb_driving_lists.dart';
import 'orb_driving_rows.dart' show orbArrivalLine;
import 'orb_driving_surface.dart';
import 'orb_operating.dart';
import 'screen/orb_screen_tools.dart';
import 'orb_prompt.dart';
import 'orb_fast_path.dart';
import 'orb_key_facts.dart';
import 'orb_key_info.dart' show orbCardKeyInfo;
import 'orb_open.dart';
import 'orb_scope.dart';
import 'orb_layer.dart';
import 'orb_state.dart';
import 'orb_summary.dart';
import 'orb_tool.dart';
import 'orb_tool_docs.dart' show orbDescribeFor, orbToolDescription;

/// Sends the summary of a session to the shared agent (the orb's header on
/// it); tests give a fake.
typedef OrbSummarySender = Future<bool> Function(
  AgentBrainChoice brain,
  List<(AgentSpeaker, String)> transcript,
  List<AgentToolOutcome> outcomes,
  String header,
);

/// Watches the Activity of [w] for driving mode (null: nothing to watch). The
/// orb disposes what it gets when driving ends.
typedef OrbActivityWatcher = OrbActivityWatch? Function(WorkspaceController w);

/// Reads the Activity briefing again for driving mode: the whole picture, not
/// what the person was told ("full"), and without marking it told.
typedef OrbLiveBriefer = Future<OrbBriefing> Function(WorkspaceController w);

OrbActivityWatch? _defaultWatcher(WorkspaceController w) {
  final store = w.activityUnreadIfBound;
  if (store == null) return null;
  return OrbActivityWatch(source: store, rows: () => store.acceptedRows);
}

Future<OrbBriefing> _defaultBriefer(WorkspaceController w) =>
    OrbBriefingService.of(w)
        .brief(OrbBriefScope.activity, full: true, remember: false);

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
    OrbActions? actions,
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
    OrbActivityWatcher? activityWatcher,
    OrbLiveBriefer? liveBriefer,
    this.liveDebounce = const Duration(seconds: 3),
    this.newBadgeLinger = const Duration(seconds: 5),
    this.agentLayer = false,
    this.layeredVoice = false,
    this.slowCue,
  }) : _now = now ?? DateTime.now,
       _activityWatcher =
           activityWatcher ?? (appTools == null ? _defaultWatcher : null),
       _liveBriefer =
           liveBriefer ?? (appTools == null ? _defaultBriefer : null),
       _warmUp =
           warmUp ??
           (appTools == null
               ? (w) => OrbBriefingService.of(w).warm(OrbBriefScope.activity)
               : null) {
    // The orb's actions: its own, or the ones a test gives (then their tools
    // join the fake ones).
    this.actions = actions ?? OrbActions(workspace: workspace);
    this.actions
      ..driving = (() => _driving)
      ..card = _cardIds
      ..appSpeaks = agentLayer
      ..replyContext = _replyContext
      ..onSay = ((line) => unawaited(voice.speak(line)));
    final all = [
      ..._shellTools(),
      ...?appTools,
      if (appTools == null)
        ...orbNavigationTools(arrivalBrief: orbArrivalBrief()),
      if (appTools == null)
        ...orbBriefingTools(
          showBriefing: (briefing, ctx) => showBriefing(briefing),
        ),
      if (appTools == null || actions != null) ...[
        ...orbTaskTools(),
        ...this.actions.tools,
        ...orbScreenTools(),
      ],
    ];
    tools = {for (final tool in all) tool.name: tool};
    voice = AgentVoiceController(
      tools: _declared(),
      onToolCall: dispatch,
      systemPrompt: _systemPrompt,
      steering: agentLayer
          ? AgentSteering(
              scope: _agentScope,
              intercept: _intercept,
              review: _review,
              preload: _preload,
              confirmation: _confirmation,
            )
          : null,
      beforeConnect: _loadBrain,
      onSessionEnd: _sessionEnded,
      onUserSaid: _userSaid,
      onModelSpoke: _modelSpoke,
      onModelTurnComplete: _modelTurnComplete,
      onModelInterrupted: _modelInterrupted,
      liveIdleLimit: liveIdleLimit,
      audio: audio,
      key: voiceKey,
      provider: agentLayer && layeredVoice ? AgentVoiceProvider.gemini : null,
      slowCue: slowCue ?? AgentVoiceController.platformSlowCue,
      fastPath: () => fastPath,
      sessionFactory:
          sessionFactory ??
          (agentLayer && layeredVoice ? createLayeredSession : null),
    )..addListener(_voiceChanged);
    voice.saying.addListener(_sayingChanged);
    // A risky press on the screen asks through the same confirm card.
    OrbScreen.of(workspace).ask = (args) => this.actions.request('act', {
      'capability': 'screen.action',
      'args': args,
    });
    this.actions
      ..onTell = ((note) => unawaited(voice.tell(note)))
      ..onTapped = _actionTapped
      ..addListener(_actionsChanged);
    operating.addListener(_operatingChanged);
    workspace.addListener(_whereChanged);
  }

  final WorkspaceController workspace;

  /// The model is a text agent behind the app's own rules (`GeminiAgentSession`
  /// and `AgentSteering`): its instruction and tools follow the state of the
  /// conversation. False: the realtime session, with the whole instruction.
  final bool agentLayer;

  /// With [agentLayer]: the voice is a Gemini Live session that only listens
  /// and speaks and hands everything to the agent (`LayeredVoiceSession`).
  /// False: the agent is typed to and its words are shown, not spoken (the
  /// evaluation).
  final bool layeredVoice;

  /// The cue the person gets when the agent behind the voice is slow (the
  /// platform's tap and click unless a test gives one).
  final void Function()? slowCue;

  /// What the model may do for the person (reply, react, change a task ...):
  /// the confirm card, the person's answer, the driving rules.
  late final OrbActions actions;

  /// Reads the Activity briefing ahead of time when the person turns to the
  /// orb, so the briefing `navigate` brings is mostly written by then.
  final Future<void> Function(WorkspaceController w)? _warmUp;

  void _warm() {
    final warmUp = _warmUp;
    if (warmUp != null) unawaited(warmUp(workspace).catchError((Object _) {}));
    _warmPreload();
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
    // The voice layer has handed the person's words to the agent and waits:
    // the orb is thinking, whatever the microphone is doing.
    if (voice.asking) return OrbState.thinking;
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
    _askNudged = false;
    // The person's own words can agree to the card on the screen.
    actions.userSaid(said);
    _whereTold = _whereBase();
    final sent = await voice.sendText(
      said,
      silentContext: await _whereLine(_whereTold!),
    );
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
    if (fresh) _askNudged = false;
    actions.userSaid(text, fresh: fresh);
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
    _nudgeIfAskedWithoutCard();
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

  /// The model asked "要发吗？" but no action is waiting: no card is up, so
  /// the person's "确认" cannot send anything (eval A3/C4 on the G100). Told
  /// once per turn of the person.
  bool _askNudged = false;
  static final _asksToConfirm = orbAsksToConfirm;

  void _nudgeIfAskedWithoutCard() {
    // The agent layer is reviewed inside the turn (see [_review]).
    if (agentLayer || _askNudged || _disposed) return;
    final last = _entries.isEmpty ? null : _entries.last;
    if (last == null || last.kind != OrbEntryKind.agent) return;
    if (actions.pending != null) return;
    if (!_asksToConfirm.hasMatch(last.text)) return;
    _askNudged = true;
    unawaited(
      voice.tell(
        '（App 提示）你问了要不要发，但还没有调用动作工具，屏幕上没有确认卡，用户说“确认”也发不出去。'
        '现在调用对应的动作工具（send_message、reply_in_thread、set_task_status 等），它只会出确认卡，不会执行；'
        '然后只说一句“确认卡已经出来了，要发吗？”。',
      ),
    );
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
    // A list is on the screen: "the N-th" is the N-th of it, not the Activity's.
    final nth = (args['n'] as num?)?.toInt();
    if (name == 'open_item' &&
        _driving &&
        !surface.isDeck &&
        nth != null &&
        args['id'] == null) {
      return openRowN(nth);
    }
    final tool = tools[name];
    if (tool == null) return {'error': '没有这个工具：$name'};
    if (agentLayer &&
        _replyTools.contains(name) &&
        actions.pending == null &&
        _turnSaid.trim().isNotEmpty &&
        !_replyIntent.hasMatch(_turnSaid)) {
      // B1: "什么需要我处理" came back as a reply to Alice nobody asked for.
      return {
        'error': '用户没有让你回复或发消息：他说的是“${_turnSaid.trim()}”。只回答他的问题，不要调用 $name。',
      };
    }
    if (agentLayer && _replyTools.contains(name)) {
      final held = _holdToTheWords(args);
      if (held.error != null) return held.error!;
      args = held.args;
    } else if (agentLayer && orbChangeTools.contains(name)) {
      // The person said what to reply: nothing else is done with it.
      final words = _sureWords();
      if (words != null) {
        _blockedWrite = true;
        return {
          'error':
              '用户要的是回复：他的原话是“${_turnSaid.trim()}”，回复内容是“${words.text}”。'
              '用 reply(text) 回复，不要调用 $name。',
        };
      }
    }
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
      agentLayer: agentLayer,
    );
    try {
      result = await tool.handler(args, toolContext);
    } catch (_) {
      result = {'error': '工具出错：$name'};
    } finally {
      operating.removeListener(watch);
    }
    if (agentLayer) result = _afterTool(name, args, result);
    if (result['status'] == 'needs_confirmation') _cardAsked = true;
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
    // While driving the layer stays: the person cannot be asked to tap.
    if (!failed &&
        !_disposed &&
        !_driving &&
        (movedScreen || workspace.location.toString() != before)) {
      collapseLayer();
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
    if (!_driving) collapseLayer();
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
    if (name == 'orb_layer') return null;
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
      'list_tasks' => '已查看任务',
      'task_detail' => '已查看任务详情',
      _ => '已调用 $name',
    };
  }

  static String _clip(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  /// The declarations of the tools this orb has, each worded for exactly
  /// these tools (a description does not point at a tool the model lacks).
  List<Map<String, Object?>> _declared() {
    final names = {
      for (final n in tools.keys)
        if (!agentLayer || !orbAgentReplaced.contains(n)) n,
    };
    return [
      for (final tool in tools.values) orbDescribeFor(tool.declaration, names),
    ];
  }

  List<OrbTool> _shellTools() => [
    OrbTool(
      declaration: {
        'name': 'orb_layer',
        'description': orbToolDescription('orb_layer'),
        'parameters': {
          'type': 'object',
          'properties': {
            'open': {'type': 'boolean', 'description': 'true 打开，false 收起'},
          },
          'required': ['open'],
        },
      },
      handler: (args, ctx) async {
        if (args['open'] == false) {
          closeLayer();
          return {'ok': true};
        }
        return {'ok': await openLayer()};
      },
    ),
    OrbTool(
      declaration: {
        'name': 'set_driving_mode',
        'description': orbToolDescription('set_driving_mode'),
        'parameters': {
          'type': 'object',
          'properties': {
            'on': {'type': 'boolean', 'description': 'true 进入，false 退出'},
          },
          'required': ['on'],
        },
      },
      handler: (args, ctx) async {
        final on = args['on'] != false;
        await setDriving(on);
        return {'ok': true, 'driving': _driving};
      },
    ),
    OrbTool(
      declaration: {
        'name': 'driving_next',
        'description': orbToolDescription('driving_next'),
      },
      handler: (args, ctx) async {
        if (!_driving) return {'error': '现在不在驾驶模式'};
        if (!surface.isDeck) return surfaceNext();
        return drivingNext();
      },
    ),
    OrbTool(
      declaration: {
        'name': 'show_list',
        'description': orbToolDescription('show_list'),
        'parameters': {
          'type': 'object',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['unread', 'mentions', 'tasks', 'channel', 'person'],
              'description': 'unread 未读的动态；mentions 点名用户的；tasks 用户名下的任务；channel 某个频道最近的消息；person 某个人的私信最近的消息',
            },
            'target': {
              'type': 'string',
              'description': 'channel 填频道名，person 填人名；其余不给',
              'maxLength': 120,
            },
          },
          'required': ['kind'],
        },
      },
      handler: (args, ctx) => showList(
        orbListKindOf(args['kind']),
        target: '${args['target'] ?? ''}',
        ctx: ctx,
      ),
    ),
    OrbTool(
      declaration: {
        'name': 'driving_back',
        'description': orbToolDescription('driving_back'),
      },
      handler: (args, ctx) async {
        if (!_driving) return {'error': '现在不在驾驶模式'};
        return surfaceBack();
      },
    ),
    if (agentLayer)
      OrbTool(
        declaration: {
          'name': 'driving_previous',
          'description': orbToolDescription('driving_previous'),
        },
        handler: (args, ctx) async {
          if (!_driving) return {'error': '现在不在驾驶模式'};
          if (!surface.isDeck) return surfacePrevious();
          return drivingPrevious();
        },
      ),
    if (agentLayer)
      OrbTool(
        declaration: {
          'name': 'next_task',
          'description': orbToolDescription('next_task'),
        },
        handler: (args, ctx) async {
          if (!_driving) return {'error': '现在不在驾驶模式'};
          return _nextTask();
        },
      ),
  ];

  // ---- driving: going through the stale tasks ---------------------------------

  /// The tasks "全部处理掉" goes through one by one: the ones the person can
  /// act on while driving, oldest first. The ones that wait for the person's
  /// review are not in it: they wait for parking, and the app says so.
  var _taskQueue = <Map<String, Object?>>[];
  var _taskAt = 0;

  /// What the app says in front of the first card of the turn: the tasks that
  /// wait for parking.
  String? _deferNote;

  /// The card now up is for the task the queue is on.
  bool _queueCard = false;

  void _clearQueue() {
    _taskQueue = [];
    _taskAt = 0;
    _deferNote = null;
    _queueCard = false;
  }

  /// `list_tasks` while driving: a queue the app holds, with the first task
  /// as `queue.current`.
  Map<String, Object?> _queueTasks(Map<String, Object?> result) {
    final rows = [
      for (final t in (result['tasks'] as List? ?? const []))
        if (t is Map) Map<String, Object?>.from(t),
    ];
    final deferred = [
      for (final t in rows)
        if (t['waitingOnMe'] == true) t,
    ];
    _taskQueue = [
      for (final t in rows)
        if (t['waitingOnMe'] != true) t,
    ];
    _taskAt = 0;
    _queueCard = false;
    _deferNote = deferred.isEmpty
        ? null
        : '${[for (final t in deferred) '「${t['title']}」'].join('、')}在等你验收，要停车后再验收。';
    return {
      ...result,
      'queue': {
        'total': _taskQueue.length,
        'current': _taskQueue.firstOrNull,
        'waitForParking': [for (final t in deferred) t['title']],
        'note': _taskQueue.isEmpty
            ? '没有可以现在处理的任务：只说“这些都要停车后再验收”'
            : '逐个处理：只对 current 提一个动作（卡住了 nudge_task，没人认领 assign_task）；'
                  'waitForParking 的任务 App 会说，你不用提，也不要改它们的状态',
      },
    };
  }

  Map<String, Object?> _nextTask() {
    if (_taskAt + 1 >= _taskQueue.length) {
      _taskAt = _taskQueue.length;
      _queueCard = false;
      return {'ok': true, 'done': true, 'note': '没有了：只说“就这些”'};
    }
    _taskAt++;
    _queueCard = false;
    return {
      'ok': true,
      'done': false,
      'index': _taskAt + 1,
      'total': _taskQueue.length,
      'current': _taskQueue[_taskAt],
    };
  }

  /// The line that tells the model where the pass over the tasks is.
  String? _queueLine() {
    if (!_driving || _taskQueue.isEmpty || _taskAt >= _taskQueue.length) {
      return null;
    }
    final t = _taskQueue[_taskAt];
    return '【任务队列】正在逐个处理任务，共 ${_taskQueue.length} 个，现在是第 ${_taskAt + 1} 个：'
        '#${t['number']}「${t['title']}」。用户说“下一个”“继续”就调用 next_task（不是 driving_next）。\n';
  }

  /// What the app adds to a tool's own words while it goes through the tasks:
  /// the ones that wait for parking, and what is left.
  Map<String, Object?> _afterTool(
    String name,
    Map<String, Object?> args,
    Map<String, Object?> result,
  ) {
    // What the briefing a tool brought says is kept for the next ask.
    final brought = orbBriefingOf([AgentToolRun(name, args, result)]);
    if (brought != null &&
        result['loading'] != true &&
        (brought['scope'] != 'activity' || _activityRead)) {
      _keepBriefing(brought);
    }
    // What the answer must convey, said by the app.
    if (_factReads.contains(name) && result['error'] == null) {
      final facts = orbKeyFactStrings(
        orbKeyFacts([AgentToolRun(name, args, result)], said: _turnSaid),
      );
      if (facts.isNotEmpty) {
        result = {
          ...result,
          'keyFacts': facts,
          'keyFactsNote': '回答要说到这些，用自己的话，别漏。',
        };
      }
    }
    if (name == 'navigate' &&
        result['error'] == null &&
        result[agentAppSays] == null &&
        actions.pending == null) {
      // "带我去 X": the person asked only to go, and the place they named is
      // surely the one it went to: the arrival is told from what was brought,
      // and the model is not asked again for it.
      final want = orbOpenArgs(_turnSaid, orbDirectoryOf(workspace));
      final line = want != null && _isPlace(want, result['matched'])
          ? orbArrivalSay(result, said: _turnSaid)
          : null;
      if (line != null) result = {...result, agentAppSays: line};
    }
    if (name == 'list_tasks' && _driving && result['error'] == null) {
      return _queueTasks(result);
    }
    final line = result[agentAppSays];
    if (line is! String) return result;
    if (name == 'confirm' || name == 'cancel_action') {
      final ok = result['status'] == 'done' || result['status'] == 'cancelled';
      if (!_queueCard || !ok) return result;
      _queueCard = false;
      final left = _taskQueue.length - _taskAt - 1;
      return {
        ...result,
        agentAppSays: left > 0 ? '$line还有 $left 个，说“下一个”继续。' : '$line就这些了。',
      };
    }
    if (result['status'] != 'needs_confirmation') return result;
    final current = _taskAt < _taskQueue.length ? _taskQueue[_taskAt] : null;
    final asked = RegExp(r'\d+').firstMatch('${args['task'] ?? ''}')?.group(0);
    if (_driving && current != null && asked == '${current['number']}') {
      _queueCard = true;
    }
    final note = _deferNote;
    _deferNote = null;
    return note == null ? result : {...result, agentAppSays: '$note$line'};
  }

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
          // Closing the layer is leaving driving mode.
          _driving = false;
          _drivingIndex = 0;
          surface.reset();
          _stopLive();
          notifyListeners();
        }
      }),
    );
    return true;
  }

  // ---- driving mode -------------------------------------------------------

  bool _driving = false;
  int _drivingIndex = 0;

  /// How long the Activity must be quiet before driving mode reads it again.
  final Duration liveDebounce;

  /// How long "新的 N 件" stays on the layer.
  final Duration newBadgeLinger;

  final OrbActivityWatcher? _activityWatcher;
  final OrbLiveBriefer? _liveBriefer;

  /// Driving mode: the layer stays open when the agent moves the app, shows
  /// one item at a time and leaves the risky actions for when the car is
  /// parked. A swipe down, Back, a tap on the backdrop or closing the layer
  /// leaves it; hanging up does not.
  bool get driving => _driving;

  /// What the person is driven through: the items that need them.
  List<OrbBriefItem> get drivingItems => shownBriefing?.needsYou ?? const [];

  /// The item on the card, counted from 0; [drivingItems].length when all are
  /// through.
  int get drivingIndex => _drivingIndex.clamp(0, drivingItems.length);

  /// All the items are through (also when there were none).
  bool get drivingDone => drivingIndex >= drivingItems.length;

  /// Turns driving mode on (opening the layer) or off (the layer stays).
  Future<void> setDriving(bool on) async {
    if (on == _driving) return;
    _driving = on;
    _drivingIndex = 0;
    surface.reset();
    _clearQueue();
    if (on) {
      _startLive();
    } else {
      _stopLive();
    }
    notifyListeners();
    if (on) await openLayer();
  }

  /// Goes to the next item (the model's `driving_next` and the chips).
  Map<String, Object?> drivingNext() {
    final items = drivingItems;
    if (_drivingIndex < items.length) {
      // The new card has been seen: its mark goes with it.
      _newKeys.remove(orbItemKey(items[_drivingIndex]));
      _drivingIndex++;
    }
    notifyListeners();
    _whereChanged();
    final done = drivingDone;
    return {
      'ok': true,
      'index': done ? items.length : drivingIndex + 1,
      'total': items.length,
      'done': done,
      if (!done) 'item': items[drivingIndex].toJson(),
      if (!done && shownBriefing != null)
        'say': orbSayHint(shownBriefing!, driving: true),
      if (done) 'note': '没有了：只说“就这些”，再说常规进度的条数',
    };
  }

  /// Back to the item before (the card of "上一件").
  Map<String, Object?> drivingPrevious() {
    final items = drivingItems;
    if (_drivingIndex > 0) _drivingIndex--;
    notifyListeners();
    _whereChanged();
    final done = drivingDone;
    return {
      'ok': true,
      'index': done ? items.length : drivingIndex + 1,
      'total': items.length,
      'done': done,
      if (!done) 'item': items[drivingIndex].toJson(),
    };
  }

  // ---- driving mode: the surfaces -------------------------------------------

  /// What the layer shows while driving besides the deck: a list, the detail
  /// of one of its rows, and the way back. The app holds it (deterministic);
  /// the model and the fast path only ask for a surface.
  final surface = OrbDrivingSurface();

  /// "新的：Alice @你": what came in live, for a few seconds, while a list or
  /// a detail is up (the deck has its own badge).
  String? _arrival;
  String? get drivingArrival => surface.isDeck ? null : _arrival;

  /// What is in front of the person: the deck's card, or the opened row.
  OrbBriefItem? get _currentItem {
    if (!_driving) return null;
    if (!surface.isDeck) return surface.detailRow?.item;
    return drivingDone ? null : drivingItems[drivingIndex];
  }

  /// The Activity briefing a list is made from: the one on the screen (kept
  /// fresh by the live push), else a read of the Activity.
  Future<OrbBriefing> _activityForList() async {
    final shown = shownBriefing;
    final OrbBriefing b;
    if (shown != null && shown.scope.isActivity && !shown.isDelta) {
      b = shown;
    } else {
      final brief = _liveBriefer;
      b = brief != null
          ? await brief(workspace)
          : await OrbBriefingService.of(workspace)
                .brief(
                  OrbBriefScope.activity,
                  full: true,
                  remember: false,
                  modelWait: const Duration(seconds: 3),
                )
                .timeout(const Duration(seconds: 8));
    }
    // Not read yet is not empty.
    if (b.isEmpty && !_activityRead) {
      throw const OrbListError('动态还在加载，稍后再试');
    }
    return b;
  }

  /// Puts a list on the screen (the model's `show_list` and the fast path):
  /// grey cards at once, the rows when they are read. The app says the total
  /// and the top one or two ([agentAppSays] for the agent layer).
  Future<Map<String, Object?>> showList(
    OrbListKind? kind, {
    String target = '',
    required OrbToolContext ctx,
  }) async {
    if (!_driving) return {'error': '现在不在驾驶模式'};
    if (kind == null) {
      return {'error': 'kind 只能是 unread、mentions、tasks、channel、person'};
    }
    final loading = OrbList.loading(kind, target: target.trim());
    surface.showList(loading);
    notifyListeners();
    final OrbList read;
    try {
      read = await orbReadDrivingList(
        kind: kind,
        target: target,
        activity: _activityForList,
        read: (tool, args) async =>
            await tools[tool]?.handler(args, ctx) ?? {'error': '现在读不了'},
      );
    } on OrbListError catch (e) {
      _dropLoading(loading);
      // ignore: raft_lints/avoid_caught_exception_text -- the app's own sentence for the person, not an exception's
      return {'error': e.message};
    } on Object {
      _dropLoading(loading);
      return {'error': '没读出来，稍后再试'};
    }
    if (_disposed) return {'error': '已经关了'};
    if (!surface.resolve(loading, read)) {
      return {'ok': true, 'note': '用户已经返回了，不用再说'};
    }
    notifyListeners();
    _whereChanged();
    return _surfaceResult(read.say);
  }

  void _dropLoading(OrbList loading) {
    if (identical(surface.list, loading)) surface.back();
    if (!_disposed) notifyListeners();
  }

  /// What a surface tool returns: where the person is and what the screen
  /// shows, and the line the app says for it.
  Map<String, Object?> _surfaceResult(String? say, {Object? error}) {
    final list = surface.list;
    final row = surface.detailRow;
    return {
      if (error != null) 'error': error else 'ok': true,
      'surface': surface.kind.name,
      if (list != null && !list.loading) ...{
        'list': list.title,
        'total': list.total,
        'page': surface.page + 1,
        'pages': surface.pageCount,
        'rows': [
          for (var i = 0; i < surface.pageRows.length; i++)
            {
              'n': i + 1,
              'who': surface.pageRows[i].who,
              'title': surface.pageRows[i].title,
              'fact': surface.pageRows[i].fact,
            },
        ],
      },
      if (row != null) 'detail': {'who': row.who, 'title': row.title},
      if (say != null) ...{
        'screenSay': say,
        if (agentLayer) agentAppSays: say else 'sayHint': '照这句说，然后停下：$say',
      },
    };
  }

  /// "下一批" on a list, "下一个" on a detail.
  Map<String, Object?> surfaceNext() {
    final list = surface.list;
    if (list == null) return drivingNext();
    if (surface.kind == OrbSurfaceKind.list) {
      if (!surface.nextPage()) return _surfaceResult('没有更多了，就这些。');
      notifyListeners();
      _whereChanged();
      return _surfaceResult(orbPageSay(list, surface.page));
    }
    if (!surface.stepDetail(1)) return _surfaceResult('这是最后一个了。');
    notifyListeners();
    _whereChanged();
    return _surfaceResult(orbRowSay(surface.detailRow!));
  }

  /// "上一个" on a detail; on a list it is "返回".
  Map<String, Object?> surfacePrevious() {
    if (surface.kind != OrbSurfaceKind.detail) return surfaceBack();
    if (!surface.stepDetail(-1)) return _surfaceResult('这是第一个。');
    notifyListeners();
    _whereChanged();
    return _surfaceResult(orbRowSay(surface.detailRow!));
  }

  /// "返回": the surface before (the list, the page before, the deck).
  Map<String, Object?> surfaceBack() {
    if (!surface.back()) return _surfaceResult('已经在最前面了。');
    notifyListeners();
    _whereChanged();
    return _surfaceResult('好。');
  }

  /// "第 N 个": the detail of the N-th row of the list on the screen.
  Map<String, Object?> openRowN(int n) {
    final list = surface.list;
    if (list == null) return _surfaceResult('屏幕上没有列表。', error: '屏幕上没有列表');
    if (list.loading) return _surfaceResult('还在读，稍等。', error: '列表还在读');
    final at = surface.indexOfNth(n);
    if (at == null || !surface.openRow(at)) {
      final say = '没有第 $n 个，一共 ${list.total} 个。';
      return _surfaceResult(say, error: say);
    }
    notifyListeners();
    _whereChanged();
    return _surfaceResult(orbRowSay(surface.detailRow!));
  }

  /// A card of a list was tapped: the same as saying its number.
  void listRowTapped(int index) {
    if (!_driving || !surface.openRow(index)) return;
    notifyListeners();
    _whereChanged();
    _saidByTap(orbRowSay(surface.detailRow!), '我点了列表里的这一个');
  }

  /// "下一个" on the detail's button.
  void detailNextTapped() {
    if (!_driving || surface.kind != OrbSurfaceKind.detail) return;
    final result = surfaceNext();
    _saidByTap('${result['screenSay'] ?? ''}', '我点了下一个');
  }

  /// "稍后" on the detail: the row is put aside, the list is back.
  void detailLaterTapped() => backTapped();

  /// The layer's "返回" or "稍后".
  void backTapped() {
    if (!_driving || surface.isDeck) return;
    surfaceBack();
  }

  /// The detail's big button: "回复" asks the person what to say (the model
  /// then makes the card); else the row opens in the app.
  void detailPrimaryTapped() {
    final row = surface.detailRow;
    if (!_driving || row == null) return;
    if (row.canReply && inCall) {
      unawaited(voice.tell('我点了「回复」：${row.say}。问我要回什么，我说完你再出确认卡，不要自己编内容。'));
      return;
    }
    final item = row.item;
    if (item != null) {
      openBriefItemTapped(item);
    } else if (row.openArgs != null) {
      unawaited(dispatch('navigate', row.openArgs!));
    }
  }

  /// A tap on the screen is said like a command: by the app's own voice in
  /// the agent layer, else the model is told what the person did.
  void _saidByTap(String line, String did) {
    if (!inCall || line.isEmpty) return;
    if (agentLayer) {
      unawaited(voice.speak(line));
    } else {
      unawaited(voice.tell('$did：$line 只说这一句，然后停下。'));
    }
  }

  /// The words on a row after a confirmed write: what the card was for.
  String _doneLabel = '已完成';

  /// A card was asked for while a detail was open; the outcome that follows
  /// puts the list back.
  bool _askedOnDetail = false;
  Object? _lastOutcome;

  void _surfaceActionsChanged(
    OrbPendingAction? pending, {
    required bool appeared,
  }) {
    if (pending != null) {
      _doneLabel =
          const {
            'messages.send',
            'messages.reply_thread',
          }.contains(pending.capabilityId)
          ? '已回复'
          : '已完成';
    }
    if (appeared) {
      _askedOnDetail = _driving && surface.kind == OrbSurfaceKind.detail;
      _lastOutcome = actions.outcome;
    }
    final outcome = actions.outcome;
    if (pending != null ||
        !_askedOnDetail ||
        outcome == null ||
        identical(outcome, _lastOutcome)) {
      return;
    }
    // A confirmed write from a detail: the list is back, the row ticked.
    _askedOnDetail = false;
    _lastOutcome = outcome;
    if (_driving &&
        outcome.kind == OrbOutcomeKind.done &&
        surface.kind == OrbSurfaceKind.detail) {
      surface.finishDetail(_doneLabel);
    }
  }

  // ---- driving mode: live push ---------------------------------------------

  OrbActivityWatch? _watch;
  Timer? _liveTimer, _badgeTimer;
  int _liveGen = 0;
  bool _liveBusy = false, _liveAgain = false;
  Future<void>? _baseline;

  /// The items (by id and version) this driving session has queued or knew
  /// of when it began: what a re-brief finds beyond them is new.
  final _seen = <String>{};

  /// The new items the person has not been on yet (they get a mark).
  final _newKeys = <String>{};

  int _newCount = 0;

  /// How many new items the layer announces ("新的 N 件"); 0 when it does not.
  int get drivingNewCount => _newCount;

  /// Whether [item] came in live and the person has not been on it yet.
  bool drivingItemIsNew(OrbBriefItem item) =>
      _newKeys.contains(orbItemKey(item));

  /// Driving began: watch the Activity. The briefing as it is now is the
  /// baseline, so that what was told before is not announced as new.
  void _startLive() {
    _stopLive();
    final make = _activityWatcher;
    final brief = _liveBriefer;
    if (make == null || brief == null) return;
    final watch = make(workspace);
    if (watch == null) return;
    _watch = watch..addListener(_liveSourceChanged);
    _seen.addAll([
      for (final i in shownBriefing?.needsYou ?? const <OrbBriefItem>[])
        orbItemKey(i),
    ]);
    final gen = _liveGen;
    final nothingShown = shownBriefing == null;
    _baseline = brief(workspace)
        .then((b) {
          if (gen != _liveGen) return;
          _seen.addAll([for (final i in b.needsYou) orbItemKey(i)]);
          // Entering pushes up what matters first (Kevin): the model need
          // not ask for it.
          if (nothingShown && shownBriefing == null && !_disposed) {
            showBriefing(b);
            if (inCall) unawaited(voice.tell(_enteredNote(b)));
          }
        })
        .catchError((Object _) {});
  }

  /// What the model hears when driving mode laid out its briefing.
  static String _enteredNote(OrbBriefing b) {
    final first = b.needsYou.firstOrNull;
    return first == null
        ? '驾驶简报已经在屏幕上：没有要处理的消息。只说一句“没有要你处理的”，再说常规的条数。'
        : '驾驶简报已经在屏幕上，共 ${b.needsYou.length} 件，第 1 件：'
              '${first.who}，${first.title}。只说这一件，最多两句，然后等用户说“下一件”。';
  }

  /// Driving ended (or the orb goes): nothing is watched, nothing waits.
  void _stopLive() {
    _liveGen++;
    _liveTimer?.cancel();
    _liveTimer = null;
    _liveBusy = _liveAgain = false;
    _baseline = null;
    _watch?.removeListener(_liveSourceChanged);
    _watch?.dispose();
    _watch = null;
    _seen.clear();
    _newKeys.clear();
    _clearBadge();
  }

  void _clearBadge() {
    _badgeTimer?.cancel();
    _badgeTimer = null;
    _newCount = 0;
    _arrival = null;
  }

  void _liveSourceChanged() {
    if (!_driving || _disposed) return;
    _liveTimer?.cancel();
    _liveTimer = Timer(liveDebounce, _liveRefresh);
  }

  Future<void> _liveRefresh() async {
    final brief = _liveBriefer;
    if (!_driving || _disposed || brief == null) return;
    // One at a time; what changed meanwhile is read once more after it.
    if (_liveBusy) {
      _liveAgain = true;
      return;
    }
    _liveBusy = true;
    final gen = _liveGen;
    try {
      await _baseline;
      final fresh = await brief(workspace);
      if (gen != _liveGen || !_driving || _disposed) return;
      _mergeLive(fresh);
    } catch (_) {
      // A read that failed changes nothing; the next change reads again.
    } finally {
      if (gen == _liveGen) {
        _liveBusy = false;
        if (_liveAgain) {
          _liveAgain = false;
          unawaited(_liveRefresh());
        }
      }
    }
  }

  /// Puts [fresh] into the queue: the card the person is on stays, the new
  /// items follow it, and the layer and the model hear about them.
  void _mergeLive(OrbBriefing fresh) {
    final shown = shownBriefing;
    if (shown == null) return;
    final merge = mergeDrivingQueue(
      queue: shown.needsYou,
      index: drivingIndex,
      seen: _seen,
      fresh: fresh.needsYou,
    );
    final before = orbQueueSignature(shown.needsYou);
    final changed =
        before != orbQueueSignature(merge.items) ||
        merge.index != drivingIndex ||
        shown.routineCount != fresh.routineCount ||
        shown.waitingTasks != fresh.waitingTasks ||
        shown.overview != fresh.overview;
    _seen.addAll([for (final i in merge.items) orbItemKey(i)]);
    shownBriefing = OrbBriefing(
      scope: shown.scope,
      overview: fresh.overview,
      needsYou: merge.items,
      progress: fresh.progress,
      routineCount: fresh.routineCount,
      waitingTasks: fresh.waitingTasks,
      waitingTaskTitles: fresh.waitingTaskTitles,
      writtenByModel: fresh.writtenByModel,
    );
    _drivingIndex = merge.index;
    if (merge.added.isNotEmpty) {
      _newKeys.addAll([for (final i in merge.added) orbItemKey(i)]);
      _newCount += merge.added.length;
      _arrival = orbArrivalLine(merge.added.first);
      _badgeTimer?.cancel();
      _badgeTimer = Timer(newBadgeLinger, () {
        if (_disposed) return;
        _newCount = 0;
        _arrival = null;
        notifyListeners();
      });
      // Said to the model only in a call; whether to speak is its call.
      if (inCall) unawaited(voice.tell(_liveNote(merge.added)));
    }
    if (changed) notifyListeners();
  }

  /// The one note to the model about [added]: what is new, and not to cut the
  /// person off for it.
  static String _liveNote(List<OrbBriefItem> added) {
    final first = added.first;
    final what = first.title.contains(first.who)
        ? first.title
        : '${first.who}：${first.title}';
    return '有新的 ${added.length} 件：$what。'
        '先别打断，等用户说完当前这件或问“还有吗”时再说；'
        '如果是有人被卡住或构建失败，可以简短提一句。';
  }

  /// "下一件" or "稍后" on the card: the item is set aside (it stays in the
  /// Activity) and the model, if a call is on, is told so that it speaks the
  /// next one.
  void drivingNextTapped() {
    if (!_driving) return;
    final result = drivingNext();
    if (!inCall) return;
    final item = result['item'];
    final line = item is Map
        ? '我点了下一件：现在是第 ${result['index']} 件，共 ${result['total']} 件，${item['title']}。'
              '不要再调 driving_next，只说这一件。'
        : '我点了下一件：已经没有了。只说“就这些”，再说常规的条数。';
    unawaited(voice.tell(line));
  }

  /// Shows [briefing] as cards in the layer, opening it when it is closed.
  void showBriefing(OrbBriefing briefing) {
    shownBriefing = briefing;
    // (An Activity briefing with nothing at all in it, before the Activity has
    // been read, is a blank, not an empty inbox.)
    if (!briefing.scope.isActivity || _activityRead || !briefing.isEmpty) {
      _keepBriefing(briefing.toJson(ordered: true));
    }
    _drivingIndex = 0;
    // A briefing laid out is the deck again.
    surface.reset();
    // What the briefing holds is not new when it comes live later.
    if (_driving) {
      _seen.addAll([for (final i in briefing.needsYou) orbItemKey(i)]);
    }
    _newKeys.clear();
    _clearBadge();
    if (_driving) _whereChanged();
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

  // ---- actions --------------------------------------------------------------

  bool _hadPending = false;

  /// The ids that name the card in front of the person while driving ("稍后
  /// 提醒我" means this one).
  List<String> _cardIds() {
    final item = _currentItem;
    if (item == null) return const [];
    return [item.id, ?item.channelId, ...item.sourceIds];
  }

  /// A confirm card came up, went, or got its result: the layer redraws, and
  /// a card that comes up while the layer is closed opens it.
  void _actionsChanged() {
    if (_disposed) return;
    final pending = actions.pending != null;
    final appeared = pending && !_hadPending;
    _hadPending = pending;
    _surfaceActionsChanged(actions.pending, appeared: appeared);
    notifyListeners();
    if (appeared && !layerOpen) unawaited(openLayer());
  }

  /// The person pressed a button on the card: it is in the transcript too (a
  /// model-asked action is, through `dispatch`).
  void _actionTapped(OrbActionOutcome outcome) {
    if (_disposed) return;
    _agentOpen = false;
    _add(
      OrbEntryKind.activity,
      outcome.kind == OrbOutcomeKind.failed
          ? '没成功：${outcome.text}'
          : outcome.text,
    );
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

  /// A turn put a confirm card up: the words that ask about it are the ones
  /// the voice layer checks its voice against.
  bool _cardAsked = false;

  KeyInfo? _confirmation() {
    final card = actions.pending;
    return _cardAsked && card != null ? orbCardKeyInfo(card) : null;
  }

  String _systemPrompt() => orbSystemPrompt(
    language: AgentVoiceSettings.instance.language,
    style: AgentVoiceSettings.instance.styleNote,
    memory: _brainContext,
    channels: orbChannelsLine(orbDirectoryOf(workspace)),
  );

  /// The person's words, before the model: a plain yes to a card they have
  /// agreed to runs `confirm` in code and a plain no that cancelled it is
  /// answered, both said by the app. Anything else is left to the model (null).
  Future<String?> _intercept(String said, AgentToolHandler run) async {
    _turnSaid = said;
    _cardAsked = false;
    fastPath = null;
    _deferNote = null;
    _replyAsked = false;
    _blockedWrite = false;
    final card = actions.pending;
    if (card != null) {
      if (!orbPlainYes(said) || card.sensitive) return null;
      // A spoken yes reaches the ledger by the transcript, which may come a
      // moment after the model's call.
      for (var i = 0; i < 6 && actions.pending?.heard != true; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (actions.pending?.heard != true) return null;
      final line = (await run('confirm', const {}))[agentAppSays];
      return line is String ? line : null;
    }
    if (orbPlainNo(said) && actions.takeCancelledByWords()) {
      await run('cancel_action', const {});
      return '好，已取消。';
    }
    return _fast(said, run);
  }

  /// Whether what `navigate` matched is the place [want] names.
  static bool _isPlace(Map<String, Object?> want, Object? matched) {
    if (matched is! Map || matched['score'] is! num || matched['score'] < .99) {
      return false;
    }
    final id = '${matched['id']}';
    return switch (matched['kind']) {
      'page' => want['page'] == id,
      'channel' => want['channel_id'] == id,
      'dm' => want['dm_id'] == id,
      'task' => '#${want['task_number']}' == id,
      _ => false,
    };
  }

  /// The command of the last turn the app did without the model (an
  /// evaluation records it); null when the model had it.
  String? fastPath;

  /// Unambiguous commands are done here, with the tool and a sentence made
  /// from its result: no model call. Null leaves the turn to the model.
  Future<String?> _fast(String said, AgentToolHandler run) async {
    final loc = workspace.location;
    final cmd = orbFastCommand(
      said,
      driving: _driving,
      onActivity: loc.route == RaftRoute.activity,
      queue: _queueLine() != null,
      directory: orbDirectoryOf(workspace),
      inConversation:
          loc.route == RaftRoute.channel || loc.route == RaftRoute.dm,
      surface: surface.kind,
    );
    if (cmd == null) return null;
    // Not read yet is not empty: the model says it is loading.
    if (cmd.kind == 'unread' && cmd.tool == 'get_briefing' && !_activityRead) {
      return null;
    }
    final result = await run(cmd.tool, cmd.args);
    String? line;
    // A list, a page, a detail or the way back: the surface says it itself.
    final screen = result['screenSay'];
    if (screen is String) {
      fastPath = cmd.kind;
      return screen;
    }
    switch (cmd.kind) {
      case 'next':
        if (cmd.tool == 'next_task') {
          line = orbTaskPassSay(result);
          // The task is on the table: the plain action for it, as a card.
          final t = result['current'];
          if (line != null && t is Map && '${t['assignee'] ?? ''}'.isNotEmpty) {
            final card = await run('nudge_task', {
              'task': t['number'],
              if ('${t['channel'] ?? ''}'.isNotEmpty) 'channel': t['channel'],
            });
            final ask = card[agentAppSays];
            if (ask is String) line = ask;
          }
        } else {
          line = orbDrivingSay(result, briefing: shownBriefing);
        }
      case 'previous':
        line = orbDrivingSay(result, briefing: shownBriefing);
      case 'park':
        line = result['error'] == null ? '好，退出驾驶模式。' : null;
      case 'drive':
        // What the model did: lay out the briefing's cards (Activity first),
        // then say the first.
        if (result['error'] != null) break;
        final deck = await run('get_briefing', const {'show': true});
        line = orbDriveSay(deck) ?? '好，驾驶模式。';
      case 'unread':
        // On the Activity: get_briefing's result. Elsewhere `navigate` only
        // moved; the briefing is read and laid out as the model would.
        var read = result;
        if (cmd.tool == 'navigate') {
          if (result['error'] != null ||
              result['candidates'] != null ||
              result['loading'] == true) {
            break;
          }
          read = await run('get_briefing', const {'show': true, 'full': true});
        }
        line = read['candidates'] == null ? orbUnreadSay(read) : null;
      case 'item':
        line = orbItemSay(result, cmd.args['n'] as int);
      case 'open':
        // Only if it landed where the words name.
        line = _isPlace(cmd.args, result['matched'])
            ? orbArrivalSay(result, said: said)
            : null;
    }
    if (line != null) fastPath = cmd.kind;
    return line;
  }

  /// Who "他" is for `reply`: the card on the screen while driving, else what
  /// needs the person (the cards the layer shows, or the Activity's).
  OrbReplyContext _replyContext() => OrbReplyContext(
    card: _currentItem,
    needsYou: () async {
      final shown = shownBriefing?.needsYou;
      if (shown != null && shown.isNotEmpty) return shown;
      final b = await OrbBriefingService.of(workspace)
          .brief(
            OrbBriefScope.activity,
            full: true,
            remember: false,
            modelWait: const Duration(seconds: 3),
          )
          .timeout(const Duration(seconds: 8));
      return b.needsYou;
    },
  );

  static const _replyTools = {'reply', 'send_message', 'reply_in_thread'};

  static const _factReads = {
    'navigate',
    'describe_page',
    'read_conversation',
    'task_detail',
    'get_briefing',
  };

  /// The person's words ask for a message to be sent.
  static final _replyIntent = RegExp(r'回|复|发|告诉|说|跟|通知|答|写|问|留言|转告|@');

  /// The model was already sent back this turn for words that were not the
  /// person's.
  bool _replyAsked = false;

  /// When the person said what the reply should say, the card carries those
  /// words (agent layer). A reply with other words is sent back once, with no
  /// card; if it still differs the app puts the person's words in itself (it
  /// already finds who it goes to).
  ({Map<String, Object?> args, Map<String, Object?>? error}) _holdToTheWords(
    Map<String, Object?> args,
  ) {
    // Only a sure reading holds the model: where the name ends and the words
    // begin is not guessed.
    final words = orbReplyWords(_turnSaid, known: _knownName);
    final want = words != null && words.sure ? words.text : null;
    final text = args['text'];
    if (want == null || (text is String && orbSameContent(text, want))) {
      return (args: args, error: null);
    }
    if (!_replyAsked) {
      _replyAsked = true;
      return (
        args: args,
        error: {
          'error':
              '回复的内容不是用户说的：他的原话是“${_turnSaid.trim()}”，要回复的话是“$want”。'
              '重新调用，text 就填“$want”，不要改写，也不要自己编。',
        },
      );
    }
    return (args: {...args, 'text': want}, error: null);
  }

  /// The model called another write tool in a turn where the person said what
  /// to reply: it was not run.
  bool _blockedWrite = false;

  /// What the person said the reply should say, when the reading is sure.
  OrbReplyWords? _sureWords() {
    final words = orbReplyWords(_turnSaid, known: _knownName);
    return words != null && words.sure ? words : null;
  }

  /// Whether [name] is a person, Agent or private conversation the App has.
  bool _knownName(String name) {
    final want = name.trim().toLowerCase();
    if (want.isEmpty) return false;
    final directory = orbDirectoryOf(workspace);
    return directory.people.any((p) => p.name.trim().toLowerCase() == want) ||
        directory.dms.any((d) => d.name.trim().toLowerCase() == want);
  }

  // ---- what the agent is told before each ask ------------------------------

  /// The briefings the app has seen, by scope, as JSON.
  final _briefs = <String, ({Map<String, Object?> json, DateTime at})>{};
  bool _preloadWarming = false;
  static const _briefFresh = Duration(minutes: 5);

  void _keepBriefing(Map<String, Object?> json) {
    final scope = json['scope'];
    if (scope is String) _briefs[scope] = (json: json, at: _now());
  }

  /// The Activity has been read: a briefing of it before that says "nothing"
  /// because nothing has come yet, and must not be kept as an empty inbox.
  bool get _activityRead =>
      workspace.activityUnreadIfBound?.hasAcceptedWindow ?? false;

  Map<String, Object?>? _freshBriefing(String scope) {
    final held = _briefs[scope];
    if (held == null || _now().difference(held.at) > _briefFresh) return null;
    return held.json;
  }

  /// Reads the Activity briefing in the background when there is none, so
  /// that the first ask of a call has it too.
  void _warmPreload() {
    final brief = _liveBriefer;
    if (!agentLayer ||
        brief == null ||
        _preloadWarming ||
        !_activityRead ||
        _freshBriefing('activity') != null) {
      return;
    }
    _preloadWarming = true;
    unawaited(
      brief(workspace)
          .then((b) {
            if (!_disposed) _keepBriefing(b.toJson(ordered: true));
          })
          .catchError((Object _) {})
          .whenComplete(() => _preloadWarming = false),
    );
  }

  /// The most characters of it.
  static const _preloadBudget = 1500;

  /// What the app already knows that an answer may need, put in front of every
  /// ask: the page, what needs the person with the key facts of each, the card
  /// of driving mode and the card that waits. With it most answers take one
  /// model call.
  String? _preload() {
    if (_disposed) return null;
    _warmPreload();
    final parts = <String>[
      '用户现在在「${orbPageTitle(workspace, workspace.location)}」页面。',
    ];
    final loc = workspace.location;
    final scopes = [
      'activity',
      if ((loc.route == RaftRoute.channel || loc.route == RaftRoute.dm) &&
          loc.thread == null &&
          loc.entityId != null)
        'conversation:${loc.entityId}',
    ];
    final lines = <String>[];
    final seen = <String>{};
    var known = false;
    for (final scope in scopes) {
      final json = _freshBriefing(scope);
      if (json == null) continue;
      known = true;
      for (final i in (json['needsYou'] as List? ?? const [])) {
        if (i is! Map || lines.length >= 4 || !seen.add('${i['id']}')) continue;
        final since = i['since'];
        final facts = [for (final f in orbItemFacts(i)) f.say];
        lines.add(
          '- ${i['title']}'
          '${since is String && since.isNotEmpty ? '（$since）' : ''}'
          '${facts.isEmpty ? '' : '。要点：${facts.join('、')}'}',
        );
      }
    }
    if (lines.isNotEmpty) {
      parts.add('等用户处理的事：\n${lines.join('\n')}');
    } else if (known) {
      parts.add('现在没有等用户处理的消息。');
    } else if (!_activityRead) {
      // Not read is not empty: without this line the model took the missing
      // list for an empty one and said "nothing".
      parts.add('动态页还没有读到内容（在加载），不知道有没有新的。问到动态时先用工具读，读不出来就说还在加载。');
    }
    final driving = _drivingLine();
    if (driving.isNotEmpty) parts.add(driving);
    final queue = _queueLine();
    if (queue != null) parts.add(queue.trim());
    final card = actions.pending;
    if (card != null) parts.add('屏幕上有一张等用户确认的卡：${card.summary}。');
    var text = parts.join('\n');
    if (text.length > _preloadBudget) {
      text = '${text.substring(0, _preloadBudget)}…';
    }
    return '（App 提示，不是用户的话。你已经知道的情况，够回答就直接答，不够再用工具读：\n$text）';
  }

  /// The person's words of the turn under way (what the review asks about).
  String _turnSaid = '';

  bool _cardMade(List<AgentToolRun> runs) =>
      runs.any((r) => r.result['status'] == 'needs_confirmation');

  /// The person said what to reply, the model reached for another write and
  /// was not let: the app asks for the reply itself (to whom is its to find).
  Future<AgentReview?> _replyInstead(
    List<AgentToolRun> runs,
    AgentToolHandler run,
  ) async {
    final words = _sureWords();
    if (!_blockedWrite ||
        words == null ||
        actions.pending != null ||
        _cardMade(runs)) {
      return null;
    }
    final line = (await run('reply', {'text': words.text}))[agentAppSays];
    return line is String ? AgentReview(text: line) : null;
  }

  static final _goThrough = RegExp(r'处理掉|全部处理|都处理|一个一个|逐个|挨个');

  /// "全部处理掉" while driving: the model read the tasks and proposed no
  /// card for the one the queue is on; the app proposes the plain action, a
  /// nudge to whoever has it.
  Future<AgentReview?> _nextTaskCard(
    List<AgentToolRun> runs,
    AgentToolHandler run,
  ) async {
    if (!_driving ||
        actions.pending != null ||
        _cardMade(runs) ||
        !_goThrough.hasMatch(_turnSaid)) {
      return null;
    }
    Map? current;
    for (final r in runs.reversed) {
      if (r.name != 'list_tasks') continue;
      final queue = r.result['queue'];
      current = queue is Map && queue['current'] is Map
          ? queue['current'] as Map
          : null;
      break;
    }
    if (current == null || current['number'] == null) return null;
    final owner = current['assignee'];
    if (owner is! String || owner.isEmpty) return null;
    final channel = current['channel'];
    final result = await run('nudge_task', {
      'task': current['number'],
      if (channel is String && channel.isNotEmpty) 'channel': channel,
    });
    final line = result[agentAppSays];
    return line is String ? AgentReview(text: line) : null;
  }

  /// The briefing scope of the page the person is on.
  OrbBriefScope? _screenScope() {
    final loc = workspace.location;
    if (loc.route == RaftRoute.activity) return OrbBriefScope.activity;
    if ((loc.route == RaftRoute.channel || loc.route == RaftRoute.dm) &&
        loc.thread == null &&
        loc.entityId != null) {
      return OrbBriefScope.conversation(loc.entityId!);
    }
    return null;
  }

  Future<AgentReview?> _review(
    String reply,
    List<AgentToolRun> runs,
    AgentToolHandler run,
  ) async {
    final proposed =
        await _replyInstead(runs, run) ?? await _nextTaskCard(runs, run);
    if (proposed != null) return proposed;
    // Whichever tool the model read the page with, what the person is told
    // about "nothing for you" and about tasks follows the briefing's data.
    final seen = await orbWithBriefing(
      runs,
      said: _turnSaid,
      screen: _screenScope,
      cached: (scope) => _freshBriefing(scope.key),
      brief: (scope) async {
        // The Activity that has not come: asking for it only waits (the inbox
        // that never answers cost ten seconds), and answers "nothing".
        if (scope.isActivity && !_activityRead) {
          throw StateError('the Activity is not read');
        }
        return OrbBriefingService.of(workspace)
            .brief(
              scope,
              full: true,
              remember: false,
              modelWait: const Duration(seconds: 3),
            )
            .timeout(const Duration(seconds: 8));
      },
    );
    return orbReviewReply(
      reply,
      seen,
      cardUp: actions.pending != null,
      driving: _driving,
      said: _turnSaid,
      retries: !layeredVoice,
      inboxUnread: !_activityRead,
    );
  }

  /// What the text agent is given for its next request: the state decides
  /// the instruction and the tools.
  AgentScope _agentScope() {
    final pending = actions.pending;
    return orbAgentScope(
      mode: orbModeOf(pending: pending != null, driving: _driving),
      driving: _driving,
      declarations: _declared(),
      language: AgentVoiceSettings.instance.language,
      style: AgentVoiceSettings.instance.styleNote,
      memory: _brainContext,
      channels: orbChannelsLine(orbDirectoryOf(workspace)),
      pending: pending?.summary,
      extra: _queueLine(),
    );
  }

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

  // ---- where the person is -------------------------------------------------

  String? _whereTold;
  Timer? _whereTimer;

  /// The page the person is on, for the model (eval C5: in a discussion
  /// "大家意见是什么" jumped to the Activity; the model did not know).
  String _whereBase() {
    final loc = workspace.location;
    final title = orbPageTitle(workspace, loc);
    return '用户现在在「$title」页面，路由 ${loc.uri}。${_drivingLine()}';
  }

  /// Driving: the card on screen is what "他/这件/回他" means (eval D3/D8:
  /// the model read the page under the layer and asked who "他" was).
  String _drivingLine() {
    if (driving && !surface.isDeck) return _surfaceLine();
    if (!driving || drivingDone) return '';
    final items = drivingItems;
    final item = items[drivingIndex];
    return '驾驶中，屏幕上是第 ${drivingIndex + 1} 件 / 共 ${items.length} 件：'
        '${item.who}，${item.title}（${item.where}）。'
        '用户说“他”“这件”“回他”“稍后提醒我”指的就是这一件。';
  }

  /// Driving, on a list or a detail: what the person sees, so that "第 2 个",
  /// "他" and "回他" mean what is on the screen.
  String _surfaceLine() {
    final list = surface.list;
    if (list == null) return '';
    if (list.loading) return '驾驶中，屏幕上是${list.title}列表，正在读。';
    final row = surface.detailRow;
    if (row != null) {
      return '驾驶中，屏幕上是「${list.title}」列表里第 ${surface.detailIndex! + 1} 个的详情：'
          '${row.meta}，${row.title}。用户说“他”“这件”“回他”指的就是它；“下一个”“返回”由 App 处理。';
    }
    final rows = surface.pageRows;
    return '驾驶中，屏幕上是「${list.heading}」列表，第 ${surface.page + 1}/${surface.pageCount} 页：'
        '${[for (var i = 0; i < rows.length; i++) '${i + 1}. ${rows[i].meta} ${rows[i].title}'].join('；')}。'
        '用户说“第 N 个”是屏幕上的第 N 个。';
  }

  /// The silent note for the model: the page and, short, what can be tapped
  /// on it (labels only: ids belong to a reading of the screen).
  Future<String> _whereLine(String base) async {
    final context = navigatorContext();
    final screen = context == null || !context.mounted
        ? ''
        : await OrbScreen.of(workspace)
              .shortLine(context)
              .timeout(const Duration(milliseconds: 800), onTimeout: () => '');
    return '（App 提示，不是用户的话：$base$screen他说“这个”“这里”“大家”时指的就是这个页面。）';
  }

  /// In a call, a move (or a new card while driving) is told to the model
  /// once, without a turn.
  void _whereChanged() {
    if (_disposed || !inCall) return;
    _whereTimer?.cancel();
    _whereTimer = Timer(const Duration(milliseconds: 400), () async {
      if (_disposed || !inCall) return;
      final base = _whereBase();
      if (base == _whereTold) return;
      _whereTold = base;
      final line = await _whereLine(base);
      if (_disposed || !inCall) return;
      voice.addContext(line);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _linger?.cancel();
    _tick?.cancel();
    _endedTimer?.cancel();
    _subtitleTimer?.cancel();
    _stopLive();
    operating.removeListener(_operatingChanged);
    workspace.removeListener(_whereChanged);
    OrbScreen.of(workspace).ask = null;
    _whereTimer?.cancel();
    voice.saying.removeListener(_sayingChanged);
    actions
      ..removeListener(_actionsChanged)
      ..dispose();
    voice.removeListener(_voiceChanged);
    callSeconds.dispose();
    voice.dispose();
    operating.dispose();
    draft.dispose();
    super.dispose();
  }
}
