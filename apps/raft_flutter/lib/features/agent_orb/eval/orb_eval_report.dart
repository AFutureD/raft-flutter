import 'dart:convert';
import 'dart:io';

import 'orb_eval_result.dart';
import 'orb_eval_run.dart';

/// Writing an evaluation down: `orb-eval/<timestamp>/report.json` (everything)
/// and `report.md` (a table to read), in the app's documents directory.

const _outcomeText = {
  OrbEvalOutcome.passed: '通过',
  OrbEvalOutcome.flaky: '不稳定',
  OrbEvalOutcome.failed: '失败',
  OrbEvalOutcome.skipped: '跳过：needs actions',
  OrbEvalOutcome.expectedFail: '预期失败：not built',
  OrbEvalOutcome.unexpectedPass: '意外通过（还没做）',
};

String _two(int n) => n.toString().padLeft(2, '0');

/// `20261017-093015`: the folder of a report.
String orbEvalStamp(DateTime at) =>
    '${at.year}${_two(at.month)}${_two(at.day)}-'
    '${_two(at.hour)}${_two(at.minute)}${_two(at.second)}';

String _cell(String text) =>
    text.replaceAll('|', r'\|').replaceAll(RegExp(r'\s*\n\s*'), '<br>');

String _short(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// A UUID shortened to its first group, so a call reads on one line.
String _brief(Object? value) => '$value'.replaceAllMapped(
  RegExp(r'([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
  (m) => '${m.group(1)}…',
);

String _call(OrbEvalToolCall c) {
  final args = [
    for (final e in c.args.entries) '${e.key}=${_short(_brief(e.value), 40)}',
  ].join(', ');
  return '${c.name}($args)';
}

/// The report as a Markdown document.
String orbEvalMarkdown(OrbEvalReport report) {
  final b = StringBuffer()
    ..writeln('# Agent 评测')
    ..writeln()
    ..writeln(
      '开始：${report.startedAt.toIso8601String()} · 每个场景 '
      '${report.runsPerScenario} 次'
      '${report.provider == null ? '' : ' · 服务 ${report.provider}'}'
      '${report.reasoning == null ? '' : ' · 推理 ${report.reasoning}'}'
      '${report.harness == null ? '' : ' · 通道 ${report.harness}'}'
      '${report.model == null ? '' : ' · 模型 ${report.model}'}'
      '${report.cancelled ? ' · 中途停止' : ''}'
      '${report.abortReason == null ? '' : '（${report.abortReason}）'}',
    )
    ..writeln()
    ..writeln(
      '结果：${report.ok ? '通过' : '有失败'}（'
      '通过 ${report.count(OrbEvalOutcome.passed)}，'
      '不稳定 ${report.count(OrbEvalOutcome.flaky)}，'
      '失败 ${report.count(OrbEvalOutcome.failed)}，'
      '跳过 ${report.count(OrbEvalOutcome.skipped)}，'
      '预期失败 ${report.count(OrbEvalOutcome.expectedFail)}，'
      '意外通过 ${report.count(OrbEvalOutcome.unexpectedPass)}）',
    )
    ..writeln()
    ..writeln('| 场景 | 说 | 结果 | 通过 | 失败的检查 | 工具调用 | Agent 说的话 |')
    ..writeln('|---|---|---|---|---|---|---|');
  for (final r in report.results) {
    final first = r.runs.firstOrNull;
    final said = [...r.scenario.setup, ...r.scenario.say].lastOrNull ?? '（事件）';
    final failed = [
      for (final e in r.failedChecks.entries)
        '${e.key}（第 ${e.value.join('、')} 次）',
    ];
    final calls = {
      for (final t in first?.run.scoredTurns ?? const <OrbEvalTurn>[])
        for (final c in t.tools) _call(c),
    };
    final text = first?.run.text ?? '';
    b.writeln(
      '| ${r.scenario.id} ${_cell(r.scenario.title)} '
      '| ${_cell(said)} '
      '| ${_outcomeText[r.outcome]} '
      '| ${r.runs.isEmpty ? '-' : '${r.passes}/${r.runs.length}'} '
      '| ${_cell(failed.join('；'))} '
      '| ${_cell(_short(calls.join('、'), 240))} '
      '| ${_cell(_short(text, 240))} |',
    );
  }
  for (final r in report.results) {
    if (r.runs.isEmpty) continue;
    b
      ..writeln()
      ..writeln('## ${r.scenario.id} ${r.scenario.title}');
    if (r.scenario.note != null) b.writeln('备注：${r.scenario.note}');
    for (final run in r.runs) {
      b
        ..writeln()
        ..writeln('第 ${run.index} 次：${run.passed ? '通过' : '失败'}');
      for (final f in run.failures) {
        b.writeln('- 检查没过：${f.check} — ${f.reason}');
      }
      if (run.error != null) b.writeln('- 运行出错：${run.error}');
      for (final t in run.run.turns) {
        b.writeln('- ${t.scored ? '说' : '（准备）说'}：${t.line}');
        for (final c in t.tools) {
          b.writeln(
            '  - 工具：${_call(c)} → ${_short(_brief(orbEvalTrim(c.result, text: 80, items: 4)), 200)}',
          );
        }
        b.writeln('  - Agent：${t.text.isEmpty ? '（没有说话）' : t.text}');
      }
      if (run.run.writes.isNotEmpty) {
        b.writeln('- 写操作：${run.run.writes.map(_brief).join('、')}');
      }
    }
  }
  return b.toString();
}

/// Writes `report.json` and `report.md` to `<root>/<timestamp>/` and a
/// `latest` file naming that folder. Returns the folder.
Future<Directory> writeOrbEvalReport(
  OrbEvalReport report,
  Directory root,
) async {
  final dir = Directory('${root.path}/${orbEvalStamp(report.startedAt)}');
  await dir.create(recursive: true);
  await File(
    '${dir.path}/report.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  await File('${dir.path}/report.md').writeAsString(orbEvalMarkdown(report));
  await File('${root.path}/latest')
      .writeAsString(orbEvalStamp(report.startedAt));
  return dir;
}
