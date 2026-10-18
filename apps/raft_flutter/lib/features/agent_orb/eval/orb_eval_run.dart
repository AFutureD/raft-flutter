import 'orb_eval_world.dart';

/// One tool the model called: what it asked for and what the app answered.
class OrbEvalToolCall {
  const OrbEvalToolCall({
    required this.name,
    required this.args,
    required this.result,
    required this.millis,
  });
  final String name;
  final Map<String, Object?> args;
  final Map<String, Object?> result;
  final int millis;

  Map<String, Object?> toJson() => {
    'name': name,
    'args': orbEvalTrim(args),
    'result': orbEvalTrim(result),
    'ms': millis,
  };
}

/// One time the voice model asked the agent (the layered harness): the words
/// it passed on, what the agent answered to say, and how long that took.
class OrbEvalAsk {
  const OrbEvalAsk({
    required this.request,
    required this.say,
    required this.millis,
  });
  final String request, say;
  final int millis;

  Map<String, Object?> toJson() => {
    'request': request,
    'say': say,
    'ms': millis,
  };
}

/// What the screen and the orb looked like when a turn ended.
class OrbEvalSnapshot {
  const OrbEvalSnapshot({
    required this.location,
    required this.layerOpen,
    required this.driving,
    required this.drivingIndex,
    required this.cards,
    this.surface = 'deck',
    this.listTitle = '',
    this.listTotal = 0,
    this.page = 0,
    this.rows = const [],
    this.speakingRow,
    this.detail,
    this.arrival,
  });

  /// The app's route (`/s/fixture/activity`).
  final String location;
  final bool layerOpen;
  final bool driving;

  /// The card in front, counted from 0.
  final int drivingIndex;

  /// The briefing cards in the layer (`needsYou`), in order: id, who, where,
  /// title. Empty when no briefing is shown.
  final List<Map<String, String>> cards;

  /// What the driving layer shows: `deck`, `list` or `detail`.
  final String surface;

  /// The list behind it ("未读 7"; empty on the deck), how many rows it has
  /// and the page on the screen (from 0).
  final String listTitle;
  final int listTotal, page;

  /// The cards of the page on the screen, in order: id, who, where, title,
  /// fact. What a person sees, not what the model said.
  final List<Map<String, String>> rows;

  /// The index in [rows] of the card that is lifted (the row being spoken).
  final int? speakingRow;

  /// The row opened large (who, title); null when none is.
  final Map<String, String>? detail;

  /// The plain line about a new arrival ("新的：Alice @你").
  final String? arrival;

  Map<String, Object?> toJson() => {
    'location': location,
    'layerOpen': layerOpen,
    'driving': driving,
    'drivingIndex': drivingIndex,
    'cards': cards,
    if (surface != 'deck') ...{
      'surface': surface,
      'listTitle': listTitle,
      'listTotal': listTotal,
      'page': page,
      'rows': rows,
      if (speakingRow != null) 'speakingRow': speakingRow,
      if (detail != null) 'detail': detail,
    },
    if (arrival != null) 'arrival': arrival,
  };
}

/// One turn of the conversation: the line the person said, then what the
/// model did.
class OrbEvalTurn {
  OrbEvalTurn(this.line, {this.scored = true});

  /// What was said (empty for a turn started by an event).
  final String line;

  /// False for the setup lines of a scenario (entering driving mode first).
  final bool scored;

  final tools = <OrbEvalToolCall>[];

  /// The asks of the voice model to the agent (the layered harness).
  final asks = <OrbEvalAsk>[];

  /// The sentences the app's voice was asked to speak, in order (the layered
  /// harness, where the app speaks).
  final spoken = <String>[];

  /// The times the app said a confirmation line itself because Live's words
  /// for it missed something: what was missing each time.
  final corrections = <List<String>>[];
  final _text = StringBuffer();

  /// From the person's text sent to the end of the model's turn.
  int millis = 0;

  /// From the person's text sent to the first sound or word of the voice
  /// after the last answer of the agent came back (what the person waits
  /// for); 0 when there was none.
  int firstAudioMs = 0;

  /// From the end of the person's words (typed text: when it was sent) to the
  /// first sound of the voice, whatever it says (a lead-in, an
  /// acknowledgment, the answer); 0 when it said nothing. The target is under
  /// a second. (The layered harness.)
  int firstVoiceMs = 0;

  /// The same to the first sentence of the answer itself.
  int firstAnswerMs = 0;

  /// Where the time of the turn went, a piece at a time, in milliseconds
  /// (the first of each in the turn): `rtt` (the socket's round trip),
  /// `transcribe`, `forward`, `request`, `say.created`, `say.firstAudio`,
  /// `lead.created`, `lead.firstAudio`. See `LayeredVoiceSession.onSegment`.
  final segments = <String, int>{};

  /// What the voice said while the agent worked, in order: `lead：…` (the
  /// voice's own words) or `ack：…` (the app's canned line).
  final feedback = <String>[];

  /// The command the app did without the model (`next`, `open` ...), when
  /// that is how the turn went.
  String? fastPath;

  /// The voice said a filler ("我看一下", "稍等") that is nothing like what the
  /// agent had for it to say (the layered harness).
  bool liveFiller = false;

  /// The time the asks to the agent took, in all.
  int get askMs => asks.fold(0, (sum, a) => sum + a.millis);

  /// The model finished its turn.
  bool completed = false;
  bool timedOut = false;

  /// How many writes the app had sent when the turn ended (reads the app
  /// posts by itself do not count): a card must be up before the first.
  int writesAfter = 0;

  /// The session failed (no key, a closed connection).
  // ignore: raft_lints/avoid_imperative_notice_state -- Written once by the runner into the report of this run; the turn lives for one run only.
  String? failure;
  OrbEvalSnapshot? after;

  String get text => _text.toString().trim();
  void addText(String chunk) => _text.write(chunk);

  Map<String, Object?> toJson() => {
    'line': line,
    'scored': scored,
    'text': text,
    if (millis > 0) 'ms': millis,
    if (firstAudioMs > 0) 'firstAudioMs': firstAudioMs,
    if (firstVoiceMs > 0) 'firstVoiceMs': firstVoiceMs,
    if (firstAnswerMs > 0) 'firstAnswerMs': firstAnswerMs,
    if (feedback.isNotEmpty) 'feedback': feedback,
    if (segments.isNotEmpty) 'segments': segments,
    if (asks.isNotEmpty) 'askMs': askMs,
    if (fastPath != null) 'fastPath': fastPath,
    if (liveFiller) 'liveFiller': true,
    'tools': [for (final t in tools) t.toJson()],
    if (asks.isNotEmpty) 'asks': [for (final a in asks) a.toJson()],
    if (spoken.isNotEmpty) 'spoken': spoken,
    if (corrections.isNotEmpty) 'corrections': corrections,
    'completed': completed,
    if (timedOut) 'timedOut': true,
    'writesAfter': writesAfter,
    if (failure != null) 'error': failure,
    if (after != null) 'after': after!.toJson(),
  };
}

/// Everything one run of a scenario produced; the checks read this.
class OrbEvalRun {
  OrbEvalRun({required this.ids});

  /// Every id the fixture holds: said out loud, it is a leak.
  final Set<String> ids;
  final turns = <OrbEvalTurn>[];
  var writes = <OrbEvalWrite>[];

  Iterable<OrbEvalTurn> get scoredTurns => turns.where((t) => t.scored);
  Iterable<OrbEvalToolCall> get tools => scoredTurns.expand((t) => t.tools);
  Iterable<OrbEvalToolCall> get allTools => turns.expand((t) => t.tools);

  /// What the model said in the scored turns.
  String get text => scoredTurns.map((t) => t.text).join('\n');
  String get allText => turns.map((t) => t.text).join('\n');

  /// How the last turn ended.
  OrbEvalSnapshot? get last => turns.lastOrNull?.after;

  /// The writes that matter: not the reads the app posts by itself (read
  /// receipts, feature flags).
  List<OrbEvalWrite> get realWrites => [
    for (final w in writes)
      if (!orbEvalIsBenignWrite(w)) w,
  ];
}

/// Requests the app sends on its own when a page opens: marking what was seen
/// as read, asking for feature flags. They change nothing the person would
/// call an action.
bool orbEvalIsBenignWrite(OrbEvalWrite w) =>
    w.method == 'POST' &&
    (w.path == '/feature-flags/evaluate' ||
        RegExp(r'^/channels/[^/]+/read$').hasMatch(w.path) ||
        w.path == '/channels/read-all');

/// Keeps a tool argument or result short enough for a report: long strings
/// and long lists are cut.
Object? orbEvalTrim(Object? value, {int text = 240, int items = 12}) {
  if (value is String) {
    return value.length <= text ? value : '${value.substring(0, text)}…';
  }
  if (value is Map) {
    return {
      for (final e in value.entries)
        '${e.key}': orbEvalTrim(e.value, text: text, items: items),
    };
  }
  if (value is List) {
    return [
      for (final e in value.take(items))
        orbEvalTrim(e, text: text, items: items),
      if (value.length > items) '…(${value.length - items} more)',
    ];
  }
  return value;
}
