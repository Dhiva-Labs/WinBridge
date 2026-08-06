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
    required this.name,
    required List<DetectionEvidence> evidence,
  }) : evidence = List.unmodifiable(evidence);

  /// Absolute, normalized path to the directory detection ran in.
  final String root;

  final ProjectType type;

  /// Display name: the manifest's own name where one exists, otherwise the
  /// directory name.
  final String name;

  /// Ordered by precedence, winner first. Never empty.
  final List<DetectionEvidence> evidence;

  DetectionEvidence get primaryEvidence => evidence.first;

  /// Evidence for types that matched but lost on precedence.
  List<DetectionEvidence> get otherEvidence =>
      [for (final e in evidence) if (e.type != type) e];

  @override
  String toString() => '$name (${type.displayName}) at $root';
}
