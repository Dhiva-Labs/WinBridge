import 'package:path/path.dart' as p;

/// Characters that must never reach a file name: path separators, traversal,
/// control codes, and the set Windows itself rejects.
final _unsafeInName = RegExp(r'[\x00-\x1f\x7f/\\:*?"<>|]');

/// Whether [value] is safe to use as a single file-name component.
///
/// A leading `-` is refused too: a name is routinely spliced into an argument
/// vector, and an argument starting with a dash is a flag to most compilers.
bool isSafeNameComponent(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    !value.startsWith('-') &&
    !_unsafeInName.hasMatch(value);

/// The project kinds WinBridge knows how to route to a toolchain.
enum ProjectType {
  flutter('Flutter'),
  go('Go'),
  rust('Rust'),
  dotnet('.NET'),
  c('C/C++');

  const ProjectType(this.displayName);

  final String displayName;
}

/// One reason detection reached a conclusion: the file that matched, and what
/// about it matched. Every candidate type that matched contributes evidence,
/// not just the winner, so `detect` can explain an ambiguous directory.
class DetectionEvidence {
  const DetectionEvidence({
    required this.type,
    required this.file,
    required this.reason,
  });

  final ProjectType type;

  /// Path relative to the project root.
  final String file;

  final String reason;

  @override
  String toString() => '$file ($reason)';
}

/// A detected project. Value object: no I/O, no behaviour.
class Project {
  Project({
    required this.root,
    required this.type,
    required String name,
    required List<DetectionEvidence> evidence,
  })  : name = isSafeNameComponent(name) ? name : _fallbackName(root),
        evidence = List.unmodifiable(evidence);

  /// Absolute, normalized path to the directory detection ran in.
  final String root;

  final ProjectType type;

  /// Display name: the manifest's own name where one exists, otherwise the
  /// directory name.
  ///
  /// Guaranteed to satisfy [isSafeNameComponent]. Adapters routinely build an
  /// output file name out of this (`'$name.exe'`), and the declared name comes
  /// from the project's own `pubspec.yaml` or `Cargo.toml` — files a hostile
  /// repository controls. A name that is not a safe component is replaced with
  /// the directory name rather than trusted, so a declared
  /// `name: ../../../../etc/cron.d/x` cannot steer a compiler's `-o` out of the
  /// output directory.
  final String name;

  static String _fallbackName(String root) {
    final base = p.basename(root);
    return isSafeNameComponent(base) ? base : 'project';
  }

  /// Ordered by precedence, winner first. Never empty.
  final List<DetectionEvidence> evidence;

  DetectionEvidence get primaryEvidence => evidence.first;

  /// Evidence for types that matched but lost on precedence.
  List<DetectionEvidence> get otherEvidence =>
      [for (final e in evidence) if (e.type != type) e];

  @override
  String toString() => '$name (${type.displayName}) at $root';
}
