import 'package:winbridge/winbridge.dart';

/// One call [FakeProcessRunner] recorded instead of spawning anything.
class RecordedRun {
  const RecordedRun(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
}

/// A [ProcessRunner] that records every call and never spawns a process.
///
/// `ProcessRunner` is the one class WinBridge lets touch `dart:io`'s
/// `Process`; overriding [run] here replaces that body entirely; nothing in
/// this file goes anywhere near `Process` itself, so it stays outside the
/// reach of `test/core/no_shell_test.dart` on its own terms rather than by
/// being exempted.
class FakeProcessRunner extends ProcessRunner {
  final calls = <RecordedRun>[];

  /// Canned per-call result, in call order. When exhausted, later calls get a
  /// zero-exit success with empty output.
  final List<RunResult> responses = [];

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    calls.add(RecordedRun(executable, arguments, workingDirectory));
    if (calls.length <= responses.length) {
      return responses[calls.length - 1];
    }
    return RunResult(
      executable: executable,
      arguments: arguments,
      exitCode: 0,
      stdout: '',
      stderr: '',
      workingDirectory: workingDirectory ?? '.',
      duration: Duration.zero,
    );
  }
}

RunResult okResult({String stdout = ''}) => RunResult(
      executable: 'fake',
      arguments: const [],
      exitCode: 0,
      stdout: stdout,
      stderr: '',
      workingDirectory: '.',
      duration: Duration.zero,
    );

RunResult failResult({String stderr = 'failed'}) => RunResult(
      executable: 'fake',
      arguments: const [],
      exitCode: 1,
      stdout: '',
      stderr: stderr,
      workingDirectory: '.',
      duration: Duration.zero,
    );
