import 'orb_actions.dart' show OrbPendingAction;

/// The words the app itself says about a confirm card (the agent layer): the
/// restatement with the question, the result, the cancellation. They come from
/// the card (who, where, the exact words), not from the model, so a model that
/// words it badly cannot leave the person with a wrong idea of what will be
/// sent.

String _clip(String text, [int max = 60]) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

String? _row(OrbPendingAction p, String label) {
  for (final r in p.rows) {
    if (r.label == label && r.value.isNotEmpty) return r.value;
  }
  return null;
}

/// "Cody：旧消息" → "Cody".
String _firstOf(String value) => value.split(RegExp('[：:]')).first.trim();

/// What the card will do, in one sentence, and the question: "回复 Cody：可以，
/// 要发吗？". A sensitive card says it only takes the buttons.
String orbRestate(OrbPendingAction p) {
  if (p.sensitive) {
    return '${p.summary}。这是敏感操作，说话不算，请你点屏幕上的确认，要点两次。';
  }
  return '${_content(p)}，要${_verb(p)}吗？';
}

String _verb(OrbPendingAction p) => switch (p.capabilityId) {
  'messages.send' || 'messages.reply_thread' => '发',
  'tasks.set_status' ||
  'tasks.assign' ||
  'tasks.unassign' ||
  'tasks.reject' => '改',
  'tasks.nudge' => '催',
  'attention.snooze' => '记下',
  _ => '做',
};

String _content(OrbPendingAction p) {
  final text = _row(p, '内容');
  switch (p.capabilityId) {
    case 'messages.send':
      final to = _row(p, '发到');
      if (to != null && text != null) {
        // A private conversation reads "发给 Ada", a channel "发到 #general".
        final dm = RegExp(r'^私信\s*(.+)$').firstMatch(to);
        return dm == null
            ? '发到 $to：${_clip(text)}'
            : '发给 ${dm[1]}：${_clip(text)}';
      }
    case 'messages.reply_thread':
      final to = _row(p, '回复');
      if (to != null && text != null) {
        return '回复 ${_firstOf(to)}：${_clip(text)}';
      }
    case 'tasks.nudge':
      final who = _row(p, '催');
      if (who != null && text != null) return '催 $who：${_clip(text)}';
    case 'tasks.set_status':
      final m = RegExp(r'^把\s*(#\d+)\b.*?\s改为\s*(\S+)$').firstMatch(p.summary);
      if (m != null) {
        final status = m[2]!;
        final word = status == '已完成' || status == '已关闭'
            ? status.substring(1)
            : status;
        return '把 ${m[1]} 标成$word';
      }
  }
  return p.summary;
}

/// The result said once the card ran: the capability's own "已发送" / "已改为
/// 已完成" / "已放一放，今晚再提醒你".
String orbDoneLine(String done) {
  final t = done.trim();
  return t.isEmpty ? '已完成。' : (RegExp(r'[。！？]$').hasMatch(t) ? t : '$t。');
}

final _plainNo = RegExp(
  r'^(?:取消|算了|不用了?|不要了?|不发了?|先不发|先不用|别发了?|不改了?|不了|no|nope)(?:吧|啊|呀|哦|了)*$',
);

String _bare(String said) =>
    said.toLowerCase().replaceAll(RegExp(r'[\s,，。.！!、~～…;；:：？?]+'), '');

/// Whether [said] is nothing but a yes to "要发吗？".
bool orbPlainYes(String said) {
  // Repeats and a few joined words: "好，发吧", "嗯 确认".
  var rest = _bare(said);
  if (rest.isEmpty || rest.length > 14) return false;
  final token = RegExp(
    r'^(?:嗯+|好+|好的|行|对+|对的|是的?|可以|确认|确定|发出去|发送|发|改|记下|催|就这样|没问题|ok|okay|yes|yep|sure|吧|啊|呀|哦|了|的)',
  );
  while (rest.isNotEmpty) {
    final m = token.firstMatch(rest);
    if (m == null) return false;
    rest = rest.substring(m.end);
  }
  return true;
}

/// Whether [said] is nothing but a no.
bool orbPlainNo(String said) {
  final bare = _bare(said);
  return bare.isNotEmpty && bare.length <= 10 && _plainNo.hasMatch(bare);
}
