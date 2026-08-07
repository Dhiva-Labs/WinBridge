import 'dart:async';
import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../core/artifact.dart';
import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/registry.dart';
import '../core/version.dart';
import '../vm/vm.dart';
import 'build_command.dart';
import 'context.dart';
import 'detect_command.dart';
import 'doctor_command.dart';
import 'run_command.dart';
import 'toolchain_setup.dart';

/// Exit codes: 0 success, 1 build or tool failure, 2 usage error.
class WinBridgeRunner extends CommandRunner<int> {
  WinBridgeRunner({
    ToolchainRegistry? registry,
    WinBridgeConfig? config,
    List<ArtifactVerifier>? verifiers,
    StringSink? out,
    StringSink? err,
  })  : _registry = registry ?? defaultRegistry(),
        _config = config,
        _verifiers = verifiers ?? defaultVerifiers(),
        _outOverride = out,
        _errOverride = err,
        super('winbridge', 'Build Windows binaries from Linux.') {
    argParser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Print every command, resolved path and tool line.',
      )
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the winbridge version.',
      );

    addCommand(BuildCommand());
    addCommand(DetectCommand());
    addCommand(DoctorCommand());
    addCommand(RunCommand());
    addCommand(VmCommand());
  }

  final ToolchainRegistry _registry;
  final WinBridgeConfig? _config;
  final List<ArtifactVerifier> _verifiers;
  final StringSink? _outOverride;
  final StringSink? _errOverride;

  // Resolved on first use so the real stdout is never touched before
  // [execute]'s zone is installed — see the note in `Output`.
  StringSink get _out => _outOverride ?? io.stdout;
  StringSink get _err => _errOverride ?? io.stderr;

  /// True when we own the process's real stdout and so are responsible for
  /// flushing it.
  bool get _ownsRealStdout => _outOverride == null;

  WinBridgeContext? _context;

  /// Available once a command has begun running.
  WinBridgeContext get context => _context!;

  /// Runs [arguments] and returns the process exit code.
  ///
  /// This is the entry point to prefer over [run]: expected failures are
  /// rendered as a message here rather than escaping as an exception, so every
  /// embedder reports them the same way. Only bugs produce a stack trace.
  ///
  /// The zone exists for one reason: `io.stdout` performs its writes inside a
  /// stream callback, so when the reader closes the pipe — `winbridge ... |
  /// head` — the resulting `EPIPE` is delivered to the zone rather than thrown
  /// from `writeln`. No `try`/`catch` around the write can see it. Here it
  /// becomes a quiet [brokenPipeExitCode] instead of a stack trace.
  Future<int> execute(List<String> arguments) {
    final finished = Completer<int>();

    void finish(int code) {
      if (!finished.isCompleted) finished.complete(code);
    }

    runZonedGuarded(
      () async {
        var code = await _execute(arguments);
        // Flushing inside the zone turns a deferred pipe error into a value we
        // can return, instead of an error arriving after main() has already
        // decided on an exit code.
        if (_ownsRealStdout) {
          try {
            await io.stdout.flush();
          } on Object catch (error) {
            if (!isBrokenPipe(error)) rethrow;
            code = brokenPipeExitCode;
          }
        }
        finish(code);
      },
      (error, stack) {
        if (isBrokenPipe(error)) {
          finish(brokenPipeExitCode);
          return;
        }
        // An asynchronous error that escaped the await chain: still a bug, and
        // reported like one rather than silently dropped.
        _writeErr('error: $error');
        _writeErr(
          _context?.output.verbose ?? false
              ? '$stack'
              : 'run with --verbose for the stack trace',
        );
        finish(1);
      },
    );

    return finished.future;
  }

  /// Writes a diagnostic, tolerating a stderr that has itself gone away.
  void _writeErr(String message) {
    try {
      _err.writeln(message);
    } on Object catch (error) {
      if (!isBrokenPipe(error)) rethrow;
    }
  }

  Future<int> _execute(List<String> arguments) async {
    try {
      return await run(arguments) ?? 0;
    } on UsageException catch (error) {
      _writeErr(error.message);
      _writeErr('');
      _writeErr(error.usage);
      return 2;
    } on WinBridgeException catch (error) {
      _writeErr('error: ${error.message}');
      if (error.details case final details?) _writeErr(details);
      return error.exitCode;
    } catch (error, stack) {
      if (isBrokenPipe(error)) return brokenPipeExitCode;
      // Anything else reaching here is a bug, so it gets to look like one.
      _writeErr('error: $error');
      _writeErr(
        _context?.output.verbose ?? false
            ? '$stack'
            : 'run with --verbose for the stack trace',
      );
      return 1;
    }
  }

  @override
  Future<int> runCommand(ArgResults topLevelResults) async {
    final context = _context = WinBridgeContext(
      registry: _registry,
      config: _config,
      verbose: topLevelResults.flag('verbose'),
      verifiers: _verifiers,
      out: _out,
      err: _err,
    );

    if (topLevelResults.flag('version')) {
      context.output.info('winbridge $packageVersion');
      return 0;
    }

    return await super.runCommand(topLevelResults) ?? 0;
  }

  @override
  void printUsage() => _out.writeln(usage);
}
