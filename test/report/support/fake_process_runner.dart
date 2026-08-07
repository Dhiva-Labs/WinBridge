import 'package:winbridge/winbridge.dart';

/// One call [FakeProcessRunner] recorded instead of spawning anything.
class RecordedRun {
  const RecordedRun(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// A [ProcessRunner] that records every call and never spawns a process.
///
/// Mirrors `test/vm/support/fake_process_runner.dart`, duplicated here rather
/// than imported: the two test suites belong to different engineers working
/// concurrently, and this file is small enough that owning a private copy
/// beats a cross-directory test dependency. `ProcessRunner` is the one class
/// WinBridge lets touch `dart:io`'s `Process`; overriding [run] here replaces
/// that body entirely; nothing in this file goes near `Process` itself.
class FakeProcessRunner extends ProcessRunner {
  final calls = <RecordedRun>[];

  /// Canned per-call result, in call order. When exhausted, later calls get
  /// a zero-exit success with empty output.
  final List<RunResult> responses = [];

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool streamOutput = false,
    bool captureOutput = true,
  }) async {
    calls.add(RecordedRun(executable, arguments));
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
