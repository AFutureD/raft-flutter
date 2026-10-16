/// Words that only stop things: nothing to ask the model, everything in
/// flight is dropped at once.
///
/// Matched on the whole utterance (punctuation and a few softeners ignored),
/// never on a word inside a longer request: "等一下，把 #9 改成完成" is a new
/// request, and "不要" alone answers a confirmation, it does not stop the
/// conversation.
const _stopWords = {
  '停',
  '停下',
  '停下来',
  '停一下',
  '停止',
  '停停',
  '别说了',
  '不说了',
  '先别说',
  '别说',
  '闭嘴',
  '安静',
  '算了',
  '算了算了',
  '算了吧',
  '算啦',
  '等一下',
  '等一等',
  '等下',
  '等等',
  '等会',
  '等会儿',
  '先等等',
  '先等一下',
  '先等下',
  '先停',
  '先停一下',
  '先别',
  '先别弄了',
  '别弄了',
  '别做了',
  '不用了',
  '不要了',
  '取消',
  '取消吧',
  '取消取消',
  '都取消',
  '全部取消',
  '不做了',
  'stop',
  'stopit',
  'cancel',
  'cancelit',
  'wait',
  'holdon',
  'nevermind',
  'nvm',
  'forgetit',
};

final _filler = RegExp(
  r'[\s,，。.！!、~～…;；:：?？]+|^(?:好|好的|嗯|哦|呃|那|那就|就|先|请|麻烦|你)(?=.)|(?:吧|啊|呀|哈)$',
);

/// Whether [raw] is only a request to stop ("停", "算了", "等一下", "stop").
bool isStopUtterance(String raw) {
  var s = raw.toLowerCase();
  if (s.runes.length > 12) return false;
  // Take off what does not change the meaning, then match what is left.
  for (var i = 0; i < 3; i++) {
    final next = s.replaceAll(_filler, '');
    if (next == s) break;
    s = next;
  }
  if (s.isEmpty) return false;
  return _stopWords.contains(s) ||
      _stopWords.contains(
        raw.toLowerCase().replaceAll(RegExp(r'[\s,，。.！!、~～…;；:：?？]+'), ''),
      );
}
