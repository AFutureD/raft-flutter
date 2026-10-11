import 'dart:io';

// Keep generator dependencies separate from the App's native build toolchain.
Future<void> main() async {
  final tools = Platform.script.resolve('bindings_generator/');
  final result = await Process.start(Platform.resolvedExecutable, [
    '--packages=${tools.resolve('.dart_tool/package_config.json').toFilePath()}',
    tools.resolve('bin/generate.dart').toFilePath(),
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await result.exitCode;
}
