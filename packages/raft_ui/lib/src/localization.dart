import 'package:flutter/widgets.dart';

import 'l10n/zh_index.g.dart' show zhCatalogAll;

// Plain-text catalog derived from pinned Web en/zh-cn catalogs (26f77ef),
// plus native UI entries. ICU messages are not interpreted by this helper.
// English is the stable source key. User-provided text is never translated.
//
// WHERE NEW STRINGS GO: the Chinese catalog is not edited here. It lives in
// l10n/zh_<feature>.dart files, each a public top-level
// `const Map<String, String> zhCatalog<Feature> = {...}` (English source ->
// Chinese, Web zh-cn.ts wording verbatim). Add your strings as a NEW file named
// after your feature; tool/gen_l10n_index.py (run by tool/flutter) merges every
// l10n/zh_*.dart into the git-ignored l10n/zh_index.g.dart, so no shared file is
// edited and parallel branches do not conflict. A key may live in only one file
// (packages/raft_ui/test/zh_catalog_files_test.dart fails on duplicates). The
// l10n/zh_web_catalog_*.dart files keep the historical Web-catalog order and are
// not a place to add.
//
// Merging a branch that still appended to the old single `raftChinese` map: git
// conflicts here (or inside this file's old tail). Take the added `"English":
// "中文",` lines out of the conflict and put them into l10n/zh_<your feature>.dart
// (a fresh file, same const-map shape), leave this file as it is. The few entries
// in [raftChineseLateAdditions] below are the former tail of the map; appending
// right after them still merges cleanly, but move such lines into a feature file.
String raftText(BuildContext context, String source) {
  if (Localizations.maybeLocaleOf(context)?.languageCode != 'zh') return source;
  return raftChinese[source] ?? source;
}

/// Fixed UI copy whose Chinese differs per Web catalog key although the English
/// source collides (for example `Unassigned`: the task property says 未指派,
/// the board filter 未分配, the history detail 取消指派). The call site names
/// the Web key's Chinese; non-Chinese locales show [source].
String raftTextZh(BuildContext context, String source, String zh) =>
    Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : source;

/// Localizes fixed UI copy before inserting untouched user-provided values.
String raftFormat(
  BuildContext context,
  String source,
  Map<String, Object?> values,
) {
  return raftText(context, source).replaceAllMapped(
    RegExp(r'\{([a-zA-Z0-9_]+)\}'),
    (match) =>
        values.containsKey(match[1]) ? '${values[match[1]] ?? ''}' : match[0]!,
  );
}

/// Localized rich text: [source] is a catalog key carrying `<tag>inner</tag>`
/// markup (the Web catalog's own rich-message form). [tags] builds the span for
/// each tag; plain text and unknown tags become plain [TextSpan]s. `{name}`
/// placeholders are filled from [values] first.
List<InlineSpan> raftRichText(
  BuildContext context,
  String source,
  Map<String, InlineSpan Function(String inner)> tags, {
  Map<String, Object?> values = const {},
}) {
  final text = raftFormat(context, source, values);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final m in RegExp(r'<(\w+)>(.*?)</\1>').allMatches(text)) {
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start)));
    }
    final build = tags[m[1]];
    spans.add(build == null ? TextSpan(text: m[2]) : build(m[2]!));
    cursor = m.end;
  }
  if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
  return spans;
}

/// Every Chinese catalog entry: the l10n/zh_*.dart files plus [raftChineseLateAdditions].
const raftChinese = <String, String>{
  ...zhCatalogAll,
  ...raftChineseLateAdditions,
};

/// Former tail of the single catalog map. Keys here must not repeat in a
/// l10n/zh_*.dart catalog (zh_catalog_files_test.dart).
const raftChineseLateAdditions = <String, String>{
  "Show": "显示",
  "Hide": "隐藏",
  "Share": "分享",
  "Discard your changes?": "放弃更改？",
  "Loading Activity": "正在加载动态…",
};
