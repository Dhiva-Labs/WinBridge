import '../detect/project.dart';
import 'output.dart';
import 'process_runner.dart';
import 'tool_resolver.dart';

enum TargetOs { windows }

enum TargetArch { x64, arm64 }

/// What we are building for. Windows is the only OS WinBridge targets, but the
/// architecture is real: `windows-arm64` is a supported Go and Rust target and
/// will be a supported VM target.
class BuildTarget {
  const BuildTarget({this.os = TargetOs.windows, this.arch = TargetArch.x64});

  static const windowsX64 = BuildTarget();
  static const windowsArm64 = BuildTarget(arch: TargetArch.arm64);
  static const all = [windowsX64, windowsArm64];

  final TargetOs os;
  final TargetArch arch;

  /// `windows-x64`. Used on the command line and as an output subdirectory.
  String get slug => '${os.name}-${arch.name}';

  static BuildTarget? parse(String value) {
    for (final target in all) {
      if (target.slug == value) return target;
    }
    return null;
  }

  @override
  String toString() => slug;

  @override
  bool operator ==(Object other) =>
      other is BuildTarget && other.os == os && other.arch == arch;

  @override
  int get hashCode => Object.hash(os, arch);
}

enum BuildMode {
  debug,
  release;

  bool get isRelease => this == BuildMode.release;
}

/// Everything a toolchain is given, and the only things it may use.
///
/// A toolchain receives its [runner], [tools] and [output] here rather than
/// reaching for globals. That is what makes the security rules checkable: an
/// adapter with no `ProcessRunner` of its own cannot spawn anything, and an
/// adapter with no `ToolResolver` of its own cannot bypass the managed
/// toolchain search order.
class BuildRequest {
  const BuildRequest({
    required this.project,
    required this.outputDirectory,
    required this.cacheDirectory,
    required this.runner,
    required this.tools,
    required this.output,
    this.target = BuildTarget.windowsX64,
    this.mode = BuildMode.release,
    this.extraArguments = const [],
  });

  final Project project;

  /// Absolute path, already created by the CLI. The only directory in the
  /// project tree an adapter may write to, and the only place its artifacts may
  /// end up — anything outside is rejected during verification.
  final String outputDirectory;

  /// Absolute path, already created by the CLI, under `~/.cache/winbridge`.
  /// For compiler caches and intermediates that should not litter the project.
  final String cacheDirectory;

  final BuildTarget target;
  final BuildMode mode;

  /// Verbatim extra arguments from the command line, appended after the
  /// adapter's own arguments. They are argv elements, never a string to split.
  final List<String> extraArguments;

  final ProcessRunner runner;
  final ToolResolver tools;
  final Output output;
}

/// What a toolchain produced, or why it did not.
///
/// Expected build failures — a compiler exiting non-zero, a target the adapter
/// cannot handle — are returned as [BuildResult.failure], not thrown. Throwing
/// is reserved for things that are not a build outcome: a missing tool
/// ([ToolNotFound]) or a bug.
class BuildResult {
  const BuildResult.success({
    required this.artifacts,
    this.summary,
    this.duration,
  })  : succeeded = true,
        failureMessage = null,
        details = null;

  const BuildResult.failure(
    String message, {
    this.details,
    this.duration,
  })  : succeeded = false,
        failureMessage = message,
        artifacts = const [],
        summary = null;

  final bool succeeded;

  /// Absolute paths to the files produced, primary artifact first.
  ///
  /// The CLI verifies every entry: it must exist, must be a file, and must sit
  /// inside [BuildRequest.outputDirectory]. A success carrying no artifacts is
  /// treated as a failure — silence is not proof of a build.
  final List<String> artifacts;

  /// One line for the user, e.g. `go 1.26.5, windows/amd64`.
  final String? summary;

  final String? failureMessage;

  /// Compiler output or other context to print beneath the failure.
  final String? details;

  final Duration? duration;

  String? get primaryArtifact => artifacts.isEmpty ? null : artifacts.first;
}
