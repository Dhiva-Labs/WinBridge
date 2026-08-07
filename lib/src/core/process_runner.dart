import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'output.dart';

/// What one external process did.
class RunResult {
  const RunResult({
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.workingDirectory,
    required this.duration,
  });

  final String executable;
  final List<String> arguments;
  final int exitCode;
  final String stdout;
  final String stderr;
  final String workingDirectory;
  final Duration duration;

  bool get ok => exitCode == 0;

  /// Human-readable rendering of the argument vector, for logs and error
  /// messages. It is display only — nothing in WinBridge parses it back, and
  /// it never reaches a shell.
  String get commandLine => renderCommand(executable, arguments);

  /// stderr if the process wrote any, otherwise stdout. What you want to show
  /// a user after a failure.
  String get diagnostics => stderr.trim().isEmpty ? stdout : stderr;
}

final _shellSafe = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// Whitespace or a NUL in an environment variable name. `execve` builds
/// `KEY=VALUE` strings from the map, and a NUL would silently truncate one.
final _invalidEnvKey = RegExp(r'[\s\x00]');

/// Renders an argument vector for display. Quoting here is cosmetic: it makes
/// arguments with spaces readable in a log. Nothing consumes the result.
String renderCommand(String executable, List<String> arguments) =>
    [executable, ...arguments].map((argument) {
      if (argument.isNotEmpty && _shellSafe.hasMatch(argument)) return argument;
      return "'${argument.replaceAll("'", r"'\''")}'";
    }).join(' ');

/// The single door to the operating system.
///
/// Every external process in WinBridge is spawned here, always as an
/// executable plus an argument vector, always with `runInShell: false`. There
/// is no code path anywhere in the package that assembles a command string, so
/// no project name, path, flag or filename can be interpreted as shell syntax.
class ProcessRunner {
  ProcessRunner({Output? output}) : _output = output ?? Output();

  final Output _output;

  /// Runs [executable] with [arguments] and waits for it to exit.
  ///
  /// [executable] must be an absolute path: resolution is `ToolResolver`'s job,
  /// so a bare name here would silently fall back to the ambient `PATH` and
  /// defeat the managed-toolchain search order.
  ///
  /// [environment] is an additive overlay on the parent environment. Its keys
  /// are logged in verbose mode; its values never are.
  ///
  /// [streamOutput] writes the child's output through as it arrives whatever
  /// the verbosity — for `winbridge run`, where the child's stdout *is* the
  /// point rather than diagnostics about it. [captureOutput] can then be
  /// turned off so a long-running app's output is not also accumulated in
  /// memory for a [RunResult] nobody reads.
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    bool streamOutput = false,
    bool captureOutput = true,
  }) async {
    if (!p.isAbsolute(executable)) {
      throw ArgumentError.value(
        executable,
        'executable',
        'must be an absolute path; resolve names with ToolResolver',
      );
    }
    for (final key in environment.keys) {
      if (key.isEmpty || key.contains('=') || _invalidEnvKey.hasMatch(key)) {
        throw ArgumentError.value(key, 'environment', 'invalid variable name');
      }
    }
    final cwd = workingDirectory == null
        ? Directory.current.path
        : p.normalize(p.absolute(workingDirectory));
    if (!Directory(cwd).existsSync()) {
      throw BuildFailure('working directory does not exist: $cwd');
    }

    final started = DateTime.now();
    _output.detail('\$ ${renderCommand(executable, arguments)}');
    _output.detail('  in $cwd');
    if (environment.isNotEmpty) {
      _output.detail('  env+ ${environment.keys.join(' ')}');
    }

    final Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        workingDirectory: cwd,
        environment: environment.isEmpty ? null : environment,
        includeParentEnvironment: true,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      throw BuildFailure(
        'could not start $executable',
        details: error.message,
      );
    }

    final out = StringBuffer();
    final err = StringBuffer();
    final collectors = [
      _collect(process.stdout, out,
          stderr: false, stream: streamOutput, capture: captureOutput),
      _collect(process.stderr, err,
          stderr: true, stream: streamOutput, capture: captureOutput),
    ];

    // The process first, its streams second. A child that leaves background
    // processes holding the same pipes — Wine's wineserver does exactly this,
    // and outlives the app it launched — never closes them, so waiting on the
    // streams before the exit code would hang forever on a program that has
    // already finished. After it exits, whatever is still in flight gets a
    // moment to arrive and then the readers are cut loose.
    final code = await process.exitCode;
    try {
      await Future.wait([for (final c in collectors) c.done])
          .timeout(_drainGrace);
    } on TimeoutException {
      for (final collector in collectors) {
        await collector.cancel();
      }
    }
    final duration = DateTime.now().difference(started);

    final result = RunResult(
      executable: executable,
      arguments: arguments,
      exitCode: code,
      stdout: out.toString(),
      stderr: err.toString(),
      workingDirectory: cwd,
      duration: duration,
    );
    _output.detail('  exit $code in ${duration.inMilliseconds}ms');
    return result;
  }

  /// [run], but a non-zero exit becomes a [ProcessFailure].
  Future<RunResult> runOrThrow(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String> environment = const {},
    String? what,
  }) async {
    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    if (!result.ok) {
      throw ProcessFailure(
        result.commandLine,
        result.exitCode,
        output: result.diagnostics,
        what: what,
      );
    }
    return result;
  }

  /// Captures the stream verbatim while echoing complete lines as they arrive.
  /// The capture is byte-exact — no trailing newline is invented — so a
  /// toolchain can trust output it parses for a version string or a path.
  ///
  /// [stream] forces the echo on for a child whose output is the point;
  /// otherwise it is verbose-only. [capture] can be turned off independently so
  /// a long-lived child does not accumulate its whole output in memory.
  _Collector _collect(
    Stream<List<int>> source,
    StringBuffer buffer, {
    required bool stderr,
    bool stream = false,
    bool capture = true,
  }) {
    final echo = stream || _output.verbose;
    void write(String line) => stream
        ? _output.app(line, stderr: stderr)
        : _output.trace(line, stderr: stderr);

    final finished = Completer<void>();
    var pending = '';

    void flush() {
      if (pending.isEmpty) return;
      write(pending);
      pending = '';
    }

    final subscription =
        source.transform(const Utf8Decoder(allowMalformed: true)).listen(
      (chunk) {
        if (capture) buffer.write(chunk);
        if (!echo) return;
        pending += chunk;
        final lastBreak = pending.lastIndexOf('\n');
        if (lastBreak < 0) return;
        for (final line in pending.substring(0, lastBreak).split('\n')) {
          write(line);
        }
        pending = pending.substring(lastBreak + 1);
      },
      onDone: () {
        flush();
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object _) {
        flush();
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: false,
    );

    return _Collector(finished.future, () async {
      await subscription.cancel();
      flush();
      if (!finished.isCompleted) finished.complete();
    });
  }
}

/// How long output already in flight gets to arrive after the process exits,
/// before its readers are abandoned.
///
/// Generous for its actual job: once the child has exited, everything it wrote
/// is already sitting in the pipe buffer and is read in a turn or two of the
/// event loop. This only elapses in full when something *else* is holding the
/// pipe open — a lingering `wineserver` — and it is charged to every
/// `winbridge run`, so it stays short enough not to be felt.
const _drainGrace = Duration(milliseconds: 500);

/// A running stream reader that can be waited on or given up on.
class _Collector {
  const _Collector(this.done, this.cancel);

  final Future<void> done;
  final Future<void> Function() cancel;
}
