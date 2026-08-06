import '../detect/project.dart';
import 'build.dart';

/// An executable a toolchain needs, and what it needs it for.
///
/// [alternatives] covers requirements with more than one acceptable provider —
/// the C toolchain is happy with either `zig` or a MinGW compiler — and
/// [optional] covers tools that unlock extra capability rather than gate the
/// build. `doctor` reports a missing optional requirement without failing.
class ToolRequirement {
  const ToolRequirement({
    required this.tool,
    required this.reason,
    this.alternatives = const [],
    this.optional = false,
  });

  /// Bare executable name, as passed to `ToolResolver.resolve`.
  final String tool;

  /// Shown by `doctor`, so write it for a human: "cross-compiles Go for
  /// windows/amd64", not "go binary".
  final String reason;

  final List<String> alternatives;
  final bool optional;

  List<String> get candidates => [tool, ...alternatives];
}

/// One way of turning a project into Windows binaries.
///
/// Implementations live in `lib/src/toolchains/` (native cross-compilers) and
/// `lib/src/vm/` (the Windows VM path). They are registered in
/// `lib/src/cli/toolchain_setup.dart`, which is the only place the CLI learns
/// they exist.
///
/// An implementation must:
///
///  * spawn processes only through [BuildRequest.runner];
///  * locate executables only through [BuildRequest.tools];
///  * write only inside [BuildRequest.outputDirectory] and
///    [BuildRequest.cacheDirectory];
///  * return artifact paths rather than reporting success on its own authority.
///
/// It must never build a shell command string, never call `Process` directly,
/// and never read a command or script path out of the project it is building.
abstract class Toolchain {
  /// Stable, lowercase identifier: `go`, `rust`, `dotnet`, `zig-cc`, `vm`.
  /// Appears in output, in cache directory names, and in error messages.
  String get id;

  /// One line describing what this adapter does, shown by `doctor`.
  String get description;

  /// Whether this adapter can build [project]. Called for every registered
  /// toolchain in registration order; the first that answers true is used.
  bool canHandle(Project project);

  /// Executables this adapter needs, for `doctor` to resolve and report.
  /// Must not perform I/O — it is called without a project in scope.
  List<ToolRequirement> requirements();

  /// Runs the build. See [BuildResult] for what to return versus throw.
  Future<BuildResult> build(BuildRequest request);
}
