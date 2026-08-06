/// Exit code for "whatever was reading our output went away", matching what a
/// shell reports for a process it killed with `SIGPIPE` (128 + 13). This is
/// what `winbridge ... | head -5` exits with, the same as coreutils.
const brokenPipeExitCode = 141;

/// Base class for failures that reach the user as a message rather than a
/// crash. Anything thrown outside this hierarchy is a bug, and the CLI prints
/// it with a stack trace so it looks like one.
abstract class WinBridgeException implements Exception {
  const WinBridgeException(this.message, {this.details});

  final String message;

  /// Extra context printed beneath [message], typically a resolved path, a
  /// search list, or the tail of a failed command's output.
  final String? details;

  /// Exit code the CLI terminates with: 2 for usage, 1 for everything else.
  int get exitCode;

  @override
  String toString() => message;
}

/// The command line itself was wrong: unknown flag, missing argument, a
/// directory that does not exist.
class UsageFailure extends WinBridgeException {
  const UsageFailure(super.message, {super.details});

  @override
  int get exitCode => 2;
}

/// The directory holds no project type WinBridge knows how to build.
class DetectionFailure extends WinBridgeException {
  const DetectionFailure(super.message, {super.details});

  @override
  int get exitCode => 1;
}

/// A required executable was not found anywhere on the resolver's search path.
class ToolNotFound extends WinBridgeException {
  ToolNotFound(
    List<String> names,
    List<String> searchedDirectories, {
    String? reason,
  })  : names = List.unmodifiable(names),
        searchedDirectories = List.unmodifiable(searchedDirectories),
        super(
          _summary(names, reason),
          details: _searchDetails(searchedDirectories),
        );

  /// The executable names that were tried, in order.
  final List<String> names;

  final List<String> searchedDirectories;

  @override
  int get exitCode => 1;

  static String _summary(List<String> names, String? reason) {
    final what = names.length == 1
        ? '`${names.single}`'
        : 'any of ${names.map((n) => '`$n`').join(', ')}';
    final because = reason == null ? '' : ' ($reason)';
    return 'could not find $what$because';
  }

  static String _searchDetails(List<String> directories) {
    if (directories.isEmpty) return 'no directories were searched';
    return ['searched:', ...directories.map((d) => '  $d')].join('\n');
  }
}

/// A build was attempted and did not produce a usable result.
class BuildFailure extends WinBridgeException {
  const BuildFailure(super.message, {super.details});

  @override
  int get exitCode => 1;
}

/// An external process exited non-zero.
class ProcessFailure extends WinBridgeException {
  ProcessFailure(
    this.commandLine,
    this.processExitCode, {
    String? output,
    String? what,
  }) : super(
          '${what ?? commandLine} failed (exit $processExitCode)',
          details: _tail(output),
        );

  /// Display-only rendering of the argument vector. Never re-parsed, never
  /// handed back to a shell.
  final String commandLine;

  final int processExitCode;

  @override
  int get exitCode => 1;

  static const _maxLines = 25;

  static String? _tail(String? output) {
    final text = output?.trimRight();
    if (text == null || text.isEmpty) return null;
    final lines = text.split('\n');
    if (lines.length <= _maxLines) return text;
    return [
      '... ${lines.length - _maxLines} earlier lines omitted',
      ...lines.skip(lines.length - _maxLines),
    ].join('\n');
  }
}

/// A toolchain reported success but its artifacts did not survive validation.
class ArtifactFailure extends WinBridgeException {
  const ArtifactFailure(super.message, {super.details});

  @override
  int get exitCode => 1;
}
