// Deterministic command-line runner for the raft_lints rules.
//
// `dart analyze` / `flutter analyze` run analyzer plugins in a separate isolate
// and print whatever has arrived when the main analysis first goes idle, so a
// warm, fast analysis can finish before the plugin reports anything. This
// runner resolves the same sources in-process and runs the very same check
// functions the plugin rules call, so the gate cannot silently skip them.
//
//   dart run raft_lints:check [dir ...]    (default: every lib/ in the repo)
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart'
        // ignore: implementation_imports
        show
        AnalysisContextCollectionImpl;
import 'package:analyzer/src/dart/analysis/file_byte_store.dart'
        // ignore: implementation_imports
        show
        FileByteStore;
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:path/path.dart' as p;
import 'package:raft_lints/src/banned_apis.dart';
import 'package:raft_lints/src/checks.dart';
import 'package:raft_lints/src/error_leak.dart';
import 'package:raft_lints/src/ignores.dart';

Future<void> main(List<String> args) async {
  final repo = p.normalize(
    p.join(p.dirname(p.fromUri(Platform.script)), '..', '..', '..'),
  );
  final roots = args.isNotEmpty
      ? [for (final a in args) p.normalize(p.absolute(a))]
      : [
          p.join(repo, 'apps', 'raft_flutter', 'lib'),
          for (final e in Directory(p.join(repo, 'packages')).listSync())
            if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
              p.join(e.path, 'lib'),
        ];
  // A persistent byte store keeps the linked SDK and package summaries between
  // runs; only the files' own function bodies are resolved again.
  final cache = Directory(p.join(repo, '.local', 'raft-lints-cache'))
    ..createSync(recursive: true);
  final AnalysisContextCollection collection = AnalysisContextCollectionImpl(
    includedPaths: roots,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
    byteStore: FileByteStore(cache.path),
  );
  final findings = <String>[];
  var files = 0;
  for (final context in collection.contexts) {
    for (final path in context.contextRoot.analyzedFiles()) {
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      if (!roots.any((r) => p.isWithin(r, path) || p.equals(r, path))) continue;
      // Cheap textual pre-filter: every rule needs one of these tokens.
      if (!_mayMatch.hasMatch(File(path).readAsStringSync())) continue;
      final result = await context.currentSession.getResolvedUnit(path);
      if (result is! ResolvedUnitResult) continue;
      files++;
      final ignores = Ignores.of(result.unit, result.content);
      result.unit.accept(
        AllChecksVisitor(path: path, (rule, node) {
          final loc = result.lineInfo.getLocation(node.offset);
          if (ignores.isIgnored(rule, loc.lineNumber)) return;
          findings.add(
            '${p.relative(path, from: repo)}:${loc.lineNumber}:${loc.columnNumber} '
            '- ${_message(rule)} ($rule)',
          );
        }),
      );
    }
  }
  findings.sort();
  findings.forEach(stdout.writeln);
  stdout.writeln(
    findings.isEmpty
        ? 'raft_lints: no issues in $files files.'
        : 'raft_lints: ${findings.length} issues in $files files.',
  );
  exitCode = findings.isEmpty ? 0 : 1;
}

/// `x[k]!`, `(x[k])!`, `.single`, `firstWhere(` / `lastWhere(` / `singleWhere(`.
final _mayMatch = RegExp(
  r'\]\s*\)*\s*!|\.single\b|\b(?:first|last|single)Where\b|'
  r'\bcatch\b|catchError|onError|SnackBar|MaterialBanner|ScaffoldMessenger|'
  r'Scheduler|Timer|Future|scheduleMicrotask|repeat|Ticker|addPostFrame|\bTimer\b|Client|Dio\b|HttpClient|WebSocket|\bio\b|findProxy|Image|Slider|underline',
);

String _message(String rule) => switch (rule) {
  indexAssertionRule => indexAssertionMessage,
  singleRule => singleMessage,
  whereRule => whereMessage,
  errorLeakRule => errorLeakMessage,
  _ => bannedApis.firstWhere((a) => a.rule == rule).message,
};
