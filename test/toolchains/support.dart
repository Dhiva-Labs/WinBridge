import 'package:winbridge/winbridge.dart';

/// One call captured by [RecordingProcessRunner], for asserting exact argv
/// and environment overlays without spawning anything.
class RecordedRun {
  RecordedRun(this.executable, this.arguments, this.environment, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
}

/// A [ProcessRunner] that records every call instead of spawning a process.
///
/// `BuildRequest.runner` is typed as the concrete `ProcessRunner`, not an
/// interface, so this works by overriding [run] on a subclass rather than by
/// implementing a separate fake — the base class is never invoked, so no
/// `Process` is ever touched here, keeping `test/core/no_shell_test.dart`
/// happy.
class RecordingProcessRunner extends ProcessRunner {
  RecordingProcessRunner({this.onRun});

  /// Called for every [run]; return null to get a canned exit-0, empty
  /// result.
  final RunResult? Function(RecordedRun call)? onRun;

  final calls = <RecordedRun>[];

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
  }) async {
    final call = RecordedRun(executable, arguments, environment, workingDirectory);
    calls.add(call);
    return onRun?.call(call) ??
        RunResult(
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

/// A quiet [Output] that writes nowhere a test would see it.
Output silentOutput() => Output(out: StringBuffer(), err: StringBuffer());

RunResult okResult({String stdout = '', String stderr = ''}) => RunResult(
      executable: '',
      arguments: const [],
      exitCode: 0,
      stdout: stdout,
      stderr: stderr,
      workingDirectory: '.',
      duration: Duration.zero,
    );

RunResult failResult({int exitCode = 1, String stderr = 'boom'}) => RunResult(
      executable: '',
      arguments: const [],
      exitCode: exitCode,
      stdout: '',
      stderr: stderr,
      workingDirectory: '.',
      duration: Duration.zero,
    );
