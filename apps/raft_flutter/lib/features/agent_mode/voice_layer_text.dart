import 'dart:math' as math;

import 'agent_language.dart';

/// The words the voice layer is given to speak with: how it phrases a short
/// lead-in, the instruction of a voice that only speaks what the app hands it
/// (OpenAI Realtime, Grok Voice), and the canned acknowledgments the app falls
/// back on. One place, so the style rules are the same for all three voice
/// services.

/// Style rules of the short line the voice says while the agent works. Kevin:
/// it must sound like a person, not a script.
String leadStyleRules(AgentLanguage language) => switch (language) {
  AgentLanguage.zh =>
    '贴着他刚说的话，带上具体的人或事（人名、频道、任务号原样说）；一句，十来个字以内；'
        '不提问，不承诺结果，不猜答案；他随口你就随口，他急你就利落；每次换个说法，不要连着两次用同一句开头；'
        '不要客服腔。\n'
        '好的例子：“嗯，Cody 那边……我看看。”“好嘞，翻一下未读。”“等我下，我去找找那条。”\n'
        '不好的例子：“正在为您查询，请稍候。”“好的，我马上为您处理。”“我看一下。”（每次都是这一句）',
  AgentLanguage.en =>
    'Stay close to what they just said and name the person or thing (names and task numbers as they are); '
        'one short line, about a dozen words at most; no question, no promise of a result, no guessing the answer; '
        'match their register, relaxed if they are relaxed, brisk if they are in a hurry; '
        'never open two lines in a row the same way; no customer-service tone.\n'
        'Good: "Hm, Cody\'s messages... let me look." "Sure, pulling up the unread." "One sec, I\'ll find that one."\n'
        'Bad: "Please wait while I look that up for you." "Certainly, I will process your request." "Let me check." (the same line every time)',
};

/// The instruction of the voice session when it only listens and speaks what
/// the app gives it (OpenAI Realtime `session.update` instructions; Grok
/// Voice's `instructions`). It never answers on its own: every response is
/// asked for by the app, with its own instruction.
String relayVoicePromptFor(AgentLanguage language) => switch (language) {
  AgentLanguage.zh =>
    '你是 Raft 里语音助手的“嗓子”，只听、只说。\n'
        '【角色】你不回答问题，不做判断，不调用工具，也不自己决定说什么：说什么、什么时候说，都由 App 在每一次请求里写明。'
        '没有收到请求的时候保持安静，一个字也不要说，也不要对用户的话做任何回应。\n'
        '【听】用户的话由 App 处理，你的任务只是听清。\n'
        '【说】每次请求会写明要说的内容，只做请求里的那一件事。\n'
        '【语言】${language.relayLine}\n'
        '声音温暖、自然，像很熟的朋友；语速正常。',
  AgentLanguage.en =>
    'You are the voice of the Raft assistant: you only listen and speak.\n'
        '[Role] You never answer questions, never judge, never call tools, and never decide what to say: '
        'the app states what to say and when in each request. When there is no request, stay silent: '
        'not a word, and no reaction to what the person says.\n'
        '[Listening] The app handles what the person says; your job is to hear it clearly.\n'
        '[Speaking] Each request says what to say; do only that one thing.\n'
        '[Language] ${language.relayLine}\n'
        'Warm and natural, like a close friend; a normal pace.',
};

/// The instruction of one response that reads the app's words aloud, exactly
/// (OpenAI Realtime has no text to speech event, so the response is told to
/// repeat the text).
String verbatimInstructionsFor(AgentLanguage language, String text) =>
    switch (language) {
      AgentLanguage.zh =>
        '把下面三引号里的话原样说给用户听：一个字不增、不删、不改，不翻译，不加开场和结尾，不解释，'
            '也不要回应这段话的内容。${language.relayLine}语气自然、温暖，像朋友说话。\n'
            '"""\n$text\n"""',
      AgentLanguage.en =>
        'Say the text between the triple quotes to the person exactly as written: do not add, drop, change or translate '
            'a word, no opening or closing, no explanation, and do not respond to what it says. '
            '${language.relayLine} Natural and warm, like a friend talking.\n'
            '"""\n$text\n"""',
    };

/// The instruction of one response that says a short lead-in while the agent
/// works: the voice phrases it from what the person just asked. [avoid] are
/// the lead-ins already said (never the same one twice in a row).
String leadInstructionsFor(
  AgentLanguage language,
  String request, {
  List<String> avoid = const [],
}) {
  final rules = leadStyleRules(language);
  final skip = avoid.isEmpty
      ? ''
      : switch (language) {
          AgentLanguage.zh =>
            '\n刚说过的接话，这次不要重复：${avoid.map((a) => '“$a”').join('')}。',
          AgentLanguage.en =>
            '\nLines you already used, do not repeat them: ${avoid.map((a) => '"$a"').join(' ')}.',
        };
  return switch (language) {
    AgentLanguage.zh =>
      '你是 Raft 语音助手的嗓子。用户刚对助手说了：“$request”。助手正在去查、去做，还没有结果。\n'
          '你现在只说一句很短的口语接话，让他知道你听到了、在办。不回答，不要说结果。\n'
          '$rules$skip\n'
          '只说这一句话，说完就停。${language.relayLine}',
    AgentLanguage.en =>
      'You are the voice of the Raft assistant. The person just said to it: "$request". '
          'The assistant is looking into it and has no result yet.\n'
          'Say one very short, conversational line so they know you heard them and are on it. Do not answer or state a result.\n'
          '$rules$skip\n'
          'Say only that one line, then stop. ${language.relayLine}',
  };
}

/// Short lines the app says itself when nothing has been said soon after the
/// person asked (the fallback of the voice's own lead-in): casual, many, and
/// never the same one twice in a row.
const _acksZh = [
  '嗯，我看看。',
  '好嘞，稍等。',
  '我找一下。',
  '等我下。',
  '哦，我查查。',
  '行，我翻翻。',
  '好，马上看。',
  '稍等哈。',
  '嗯嗯，我看下。',
  '来，我瞅瞅。',
  '好的，我去看看。',
  '收到，我来找找。',
];

const _acksEn = [
  'Sure, one sec.',
  'Let me look.',
  'On it.',
  'Hang on, checking.',
  'Okay, give me a sec.',
  'Mm, let me see.',
  'Got it, looking.',
  'Hold on a moment.',
  'Right, let me check.',
  'Hm, let me find that.',
  'Yep, give me a second.',
  'Okay, looking now.',
];

/// Every canned acknowledgment of [language].
List<String> ackPhrases(AgentLanguage language) =>
    language == AgentLanguage.zh ? _acksZh : _acksEn;

/// Picks the next canned acknowledgment: random, and never one of the last two
/// said.
class AckPicker {
  AckPicker({math.Random? random}) : _random = random ?? math.Random();
  final math.Random _random;
  final _recent = <String>[];

  String next(AgentLanguage language) {
    final all = ackPhrases(language);
    final fresh = [
      for (final a in all)
        if (!_recent.contains(a)) a,
    ];
    final pool = fresh.isEmpty ? all : fresh;
    final pick = pool[_random.nextInt(pool.length)];
    _recent.add(pick);
    if (_recent.length > 2) _recent.removeAt(0);
    return pick;
  }
}

/// What is said when the agent could not answer.
String agentFailedLine(AgentLanguage language) => switch (language) {
  AgentLanguage.zh => '我这边出了点问题，你再说一次。',
  AgentLanguage.en =>
    'Something went wrong on my side. Could you say that again?',
};

/// [text] as the voice model is given it to say. A number written "#136"
/// often ends Live's answer right there, so it reads "136": the same number
/// to the ear.
String layeredForVoice(String text) =>
    text.replaceAllMapped(RegExp(r'#(\d)'), (m) => m[1]!);
