import 'dart:math';

import 'package:flutter/foundation.dart';

import 'agent_capability.dart';

/// Whether the person has agreed to a previewed operation.
///
/// The model never decides this. A confirmation token becomes confirmable
/// only after a signal that came from the person in this session: a tap on
/// the confirm card the app drew for that token, or (for an ordinary change,
/// never a sensitive one) their own typed or transcribed words after the
/// preview was on screen. Anything the model writes or says is not a signal;
/// it is never given to this class.
enum AgentConsentVerdict {
  /// The person agreed. Taking it spends the token.
  granted,

  /// No signal yet (or none that counts): ask the person, do nothing.
  pending,

  /// The person said no (cancel button, "不要", "算了"), or the token ran out.
  declined,
}

/// One previewed operation waiting for the person.
@immutable
class AgentConsentRequest {
  const AgentConsentRequest({
    required this.token,
    required this.capabilityId,
    required this.preview,
    required this.risk,
    required this.expires,
    this.step = 1,
    this.total = 1,
  });

  final String token;
  final String capabilityId;
  final AgentActionPreview preview;
  final AgentCapabilityRisk risk;
  final DateTime expires;

  /// Sensitive operations are confirmed twice: 1/2, then 2/2.
  final int step, total;

  bool get sensitive => risk == AgentCapabilityRisk.sensitive;
}

/// What [AgentCapabilityTools] asks before it runs anything.
abstract interface class AgentUserConsent {
  /// The preview of [request] is now in front of the person (the app draws
  /// its confirm card). Only after this can a signal count for the token.
  void previewShown(AgentConsentRequest request);

  /// The person's answer for [token]. [AgentConsentVerdict.granted] is given
  /// once: the token is spent by taking it.
  AgentConsentVerdict take(String token);
}

/// What the words of a person mean for a pending confirmation.
enum AgentUtterance { yes, no, other }

/// Phrases that contain an affirmative word without being one.
const _falseFriends = [
  '好多', '好像', '好些', '好几', '好久', '好处', '好看', '好玩', '好奇', //
  '对于', '对面', '对比', '对象', '对话', '对方', '对应', '对错',
  '行动', '运行', '进行', '银行', '行为', '行程', '执行情况',
  '是否', '是不是', '还是', '但是', '可是', '只是', '就是', '总是', '或者是',
];

final _negation = RegExp(
  r'不|别|没|否|勿|取消|算了|等等|等一下|等会|先停|停下|拒绝|'
  r"\b(?:no|nope|nah|don'?t|do not|dont|cancel|stop|wait|never|not)\b",
);

final _affirmation = RegExp(
  r'对|好|行|嗯|确认|可以|是的|是啊|同意|做吧|执行|批准|没问题|'
  r'\b(?:yes|yeah|yep|yup|ok|okay|sure|confirm|confirmed|go ahead|do it|proceed|fine|agreed?)\b',
);

/// The longest an agreeing answer is: a sentence that is longer is a new
/// request that happens to contain "好".
const _agreeMaxLength = 14;

/// Reads [raw] as the person's answer to "shall I do this?".
///
/// Negation anywhere wins ("好吧，不用了" is a no). A question ("可以吗？") or a
/// long sentence is not an answer. Otherwise a short sentence with an
/// affirmative word (对 / 好 / 确认 / 可以 / yes / ok …) is a yes.
AgentUtterance classifyUtterance(String raw) {
  var s = raw.toLowerCase();
  // "没问题" holds a negation character and means yes.
  s = s.replaceAll('没问题', '可以').replaceAll('没关系', '可以');
  if (_negation.hasMatch(s)) return AgentUtterance.no;
  if (RegExp(r'[?？吗呢]').hasMatch(s)) return AgentUtterance.other;
  for (final f in _falseFriends) {
    s = s.replaceAll(f, ' ');
  }
  final bare = s.replaceAll(RegExp(r'[\s,，。.！!、~～…;；:：]+'), '');
  if (bare.isEmpty || bare.length > _agreeMaxLength) return AgentUtterance.other;
  return _affirmation.hasMatch(s) ? AgentUtterance.yes : AgentUtterance.other;
}

/// A confirmation the person can see: the card, and whether it was pressed.
@immutable
class AgentPendingConfirmation {
  const AgentPendingConfirmation(this.cardId, this.request, this.approved);

  /// Names the card; unrelated to the token, which the model knows. A press
  /// on a card of the model's own making can therefore never match.
  final String cardId;
  final AgentConsentRequest request;
  final bool approved;
}

class _Entry {
  _Entry(this.cardId, this.request, this.since);
  final String cardId;
  final AgentConsentRequest request;

  /// The utterance counter when the preview was shown: only words that began
  /// after it count.
  final int since;
  bool approved = false;
  bool declined = false;
}

/// The record of what the person has agreed to, in this session.
///
/// Fed only from the person: [cardTapped] from the confirm card, [userSaid]
/// from their typed text and the transcript of their speech. See
/// [AgentConsentVerdict].
class AgentConsentLedger extends ChangeNotifier implements AgentUserConsent {
  AgentConsentLedger({DateTime Function()? now, Random? random})
    : _now = now ?? DateTime.now,
      _random = random ?? Random.secure();

  final DateTime Function() _now;
  final Random _random;

  /// Previews waiting at once; the oldest give way (a model that previews
  /// again and again cannot bury the one the person is looking at).
  static const maxPending = 3;

  final _entries = <String, _Entry>{};

  int _utterance = 0;
  String _said = '';

  /// A press on a card of this ledger decided [request].
  void Function(AgentConsentRequest request, bool yes)? onTapped;

  /// The confirmations on screen, oldest first.
  List<AgentPendingConfirmation> get active {
    _prune();
    return [
      for (final e in _entries.values)
        if (!e.declined) AgentPendingConfirmation(e.cardId, e.request, e.approved),
    ];
  }

  /// When the next confirmation runs out, for a timer that clears the card.
  DateTime? get nextExpiry => _entries.values.isEmpty
      ? null
      : _entries.values
            .map((e) => e.request.expires)
            .reduce((a, b) => a.isBefore(b) ? a : b);

  bool _prune() {
    final now = _now();
    final gone = [
      for (final e in _entries.entries)
        if (!now.isBefore(e.value.request.expires)) e.key,
    ];
    for (final k in gone) {
      _entries.remove(k);
    }
    return gone.isNotEmpty;
  }

  /// Drops what ran out; tells the card tray.
  void prune() {
    if (_prune()) notifyListeners();
  }

  @override
  void previewShown(AgentConsentRequest request) {
    _prune();
    _entries.remove(request.token);
    while (_entries.length >= maxPending) {
      _entries.remove(_entries.keys.first);
    }
    _entries[request.token] = _Entry(_cardId(), request, _utterance);
    notifyListeners();
  }

  String _cardId() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    return 'pv_${List.generate(10, (_) => chars[_random.nextInt(chars.length)]).join()}';
  }

  /// The card with [cardId] was pressed: 确认 ([yes]) or 取消. False when no
  /// live confirmation has that card (a card the model drew, one that ran
  /// out, one already decided).
  bool cardTapped(String cardId, {required bool yes}) {
    _prune();
    final entry = _entries.values
        .where((e) => e.cardId == cardId && !e.declined && !e.approved)
        .firstOrNull;
    if (entry == null) return false;
    if (yes) {
      entry.approved = true;
    } else {
      entry.declined = true;
    }
    notifyListeners();
    onTapped?.call(entry.request, yes);
    return true;
  }

  /// Words of the person: typed text, or a chunk of the transcript of their
  /// speech. [fresh] starts a new utterance (typed text always does; a
  /// transcript chunk does when it is not the continuation of the last).
  ///
  /// A yes approves the newest ordinary-change confirmation that was shown
  /// before these words; a no cancels every one. A sensitive operation is
  /// never approved by words.
  void userSaid(String text, {bool fresh = true}) {
    if (text.trim().isEmpty) return;
    if (fresh) {
      _utterance++;
      _said = '';
    }
    _said += text;
    _prune();
    final eligible = [
      for (final e in _entries.values)
        if (!e.declined && e.since < _utterance) e,
    ];
    if (eligible.isEmpty) return;
    switch (classifyUtterance(_said)) {
      case AgentUtterance.no:
        for (final e in eligible) {
          e.declined = true;
          e.approved = false;
        }
        notifyListeners();
      case AgentUtterance.yes:
        final open = eligible.where((e) => !e.approved && !e.request.sensitive);
        if (open.isEmpty) return;
        open.last.approved = true;
        notifyListeners();
      case AgentUtterance.other:
        break;
    }
  }

  @override
  AgentConsentVerdict take(String token) {
    final changed = _prune();
    final entry = _entries[token];
    AgentConsentVerdict verdict;
    if (entry == null) {
      verdict = AgentConsentVerdict.pending;
    } else if (entry.declined) {
      _entries.remove(token);
      verdict = AgentConsentVerdict.declined;
    } else if (entry.approved) {
      _entries.remove(token);
      verdict = AgentConsentVerdict.granted;
    } else {
      verdict = AgentConsentVerdict.pending;
    }
    if (changed || verdict != AgentConsentVerdict.pending) notifyListeners();
    return verdict;
  }

  /// Forgets everything (the session ended).
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
