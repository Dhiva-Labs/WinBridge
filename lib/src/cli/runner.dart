import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../core/artifact.dart';
import '../core/config.dart';
import '../core/errors.dart';
import '../core/registry.dart';
import '../core/version.dart';
import '../vm/vm.dart';
import 'build_command.dart';
import 'context.dart';
import 'detect_command.dart';
import 'doctor_command.dart';
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
        _out = out ?? io.stdout,
        _err = err ?? io.stderr,
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
    addCommand(VmCommand());
  }

  final ToolchainRegistry _registry;
  final WinBridgeConfig? _config;
  final List<ArtifactVerifier> _verifiers;
  final StringSink _out;
  final StringSink _err;

  WinBridgeContext? _context;

  /// Available once a command has begun running.
  WinBridgeContext get context => _context!;

  /// Runs [arguments] and returns the process exit code.
  ///
  /// This is the entry point to prefer over [run]: expected failures are
  /// rendered as a message here rather than escaping as an exception, so every
  /// embedder reports them the same way. Only bugs produce a stack trace.
  Future<int> execute(List<String> arguments) async {
    try {
      return await run(arguments) ?? 0;
    } on UsageException catch (error) {
      _err
        ..writeln(error.message)
        ..writeln()
        ..writeln(error.usage);
      return 2;
    } on WinBridgeException catch (error) {
      _err.writeln('error: ${error.message}');
      if (error.details != null) _err.writeln(error.details);
      return error.exitCode;
    } catch (error, stack) {
      // Anything reaching here is a bug, so it gets to look like one.
      _err.writeln('error: $error');
      if (_context?.output.verbose ?? false) {
        _err.writeln(stack);
      } else {
        _err.writeln('run with --verbose for the stack trace');
      }
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
