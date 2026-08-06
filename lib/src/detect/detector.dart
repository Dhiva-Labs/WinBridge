import 'dart:io';

import 'package:path/path.dart' as p;

import 'project.dart';
import 'pubspec.dart';

/// Identifies what kind of project a directory holds.
///
/// Detection looks at the given directory only — it does not recurse into
/// subdirectories and does not walk up towards a repository root. A monorepo is
/// therefore built one package directory at a time, which keeps the answer
/// predictable: the same directory always yields the same result regardless of
/// what surrounds it.
///
/// Markers are evaluated in [precedence] order and the first match wins. The
/// order runs from the most specific marker to the least: a `pubspec.yaml` that
/// pulls in Flutter can mean nothing else, while a `Makefile` is a weak hint
/// that plenty of Go and Rust projects also carry.
class ProjectDetector {
  const ProjectDetector();

  static const precedence = <ProjectType>[
    ProjectType.flutter,
    ProjectType.go,
    ProjectType.rust,
    ProjectType.dotnet,
    ProjectType.c,
  ];

  /// The markers detection looks for, in precedence order. Used verbatim in
  /// the "nothing found" message so the docs cannot drift from the code.
  static const markers = <String>[
    'pubspec.yaml with a flutter dependency  -> Flutter',
    'go.mod                                  -> Go',
    'Cargo.toml                              -> Rust',
    '*.csproj / *.fsproj                     -> .NET',
    'CMakeLists.txt, Makefile or *.c/*.cpp   -> C/C++',
  ];

  static const _cSourceExtensions = {'.c', '.cpp', '.cc', '.cxx'};
  static const _makefiles = {'Makefile', 'makefile', 'GNUmakefile'};

  /// Returns null when [directory] is missing, unreadable, or holds nothing
  /// recognizable.
  Project? detect(String directory) {
    final root = p.normalize(p.absolute(directory));
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(root).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }

    final files = <String>{};
    for (final entry in entries) {
      if (entry is Directory) continue;
      files.add(p.basename(entry.path));
    }

    final evidence = <ProjectType, DetectionEvidence>{};
    final names = <ProjectType, String>{};

    void record(ProjectType type, String file, String reason, [String? name]) {
      evidence.putIfAbsent(
        type,
        () => DetectionEvidence(type: type, file: file, reason: reason),
      );
      if (name != null && name.isNotEmpty) names.putIfAbsent(type, () => name);
    }

    if (files.contains('pubspec.yaml')) {
      final pubspec = Pubspec.parse(_read(root, 'pubspec.yaml') ?? '');
      if (pubspec.usesFlutter) {
        record(
          ProjectType.flutter,
          'pubspec.yaml',
          'declares a flutter dependency',
          pubspec.name,
        );
      }
    }

    if (files.contains('go.mod')) {
      record(
        ProjectType.go,
        'go.mod',
        'go module',
        _goModuleName(_read(root, 'go.mod')),
      );
    }

    if (files.contains('Cargo.toml')) {
      record(
        ProjectType.rust,
        'Cargo.toml',
        'cargo manifest',
        _cargoPackageName(_read(root, 'Cargo.toml')),
      );
    }

    final projectFile = files
        .where((f) => f.endsWith('.csproj') || f.endsWith('.fsproj'))
        .toList()
      ..sort();
    if (projectFile.isNotEmpty) {
      record(
        ProjectType.dotnet,
        projectFile.first,
        'msbuild project',
        p.basenameWithoutExtension(projectFile.first),
      );
    }

    if (files.contains('CMakeLists.txt')) {
      record(ProjectType.c, 'CMakeLists.txt', 'cmake project');
    } else {
      final makefile = _makefiles.firstWhere(
        files.contains,
        orElse: () => '',
      );
      if (makefile.isNotEmpty) {
        record(ProjectType.c, makefile, 'make build');
      } else {
        final sources = files
            .where((f) => _cSourceExtensions.contains(p.extension(f)))
            .toList()
          ..sort();
        if (sources.isNotEmpty) {
          record(ProjectType.c, sources.first, 'C/C++ sources');
        }
      }
    }

    final ordered = [for (final type in precedence) ?evidence[type]];
    if (ordered.isEmpty) return null;

    final type = ordered.first.type;
    return Project(
      root: root,
      type: type,
      name: names[type] ?? p.basename(root),
      evidence: ordered,
    );
  }

  static String? _read(String root, String file) {
    try {
      return File(p.join(root, file)).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  static final _goModule = RegExp(r'^module\s+(\S+)', multiLine: true);

  static String? _goModuleName(String? source) {
    if (source == null) return null;
    final match = _goModule.firstMatch(source);
    final path = match?.group(1);
    if (path == null) return null;
    return path.split('/').last;
  }

  static final _cargoName =
      RegExp(r'''^\s*name\s*=\s*["']([^"']+)["']''', multiLine: true);

  static String? _cargoPackageName(String? source) {
    if (source == null) return null;
    // The first `name = "..."` in a manifest belongs to [package]; keys under
    // [dependencies] use the dependency name as the key instead.
    return _cargoName.firstMatch(source)?.group(1);
  }
}
