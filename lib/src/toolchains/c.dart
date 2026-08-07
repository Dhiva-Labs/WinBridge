import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/build.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';

const _cxxExtensions = {'.cpp', '.cc', '.cxx'};
const _sourceExtensions = {'.c', '.cpp', '.cc', '.cxx'};

/// Compiles top-level and `src/` C/C++ sources directly for windows/amd64.
///
/// Prefers `zig cc`/`zig c++` — one download, no system packages — and falls
/// back to a MinGW-w64 cross-compiler. This M1 adapter does not drive CMake
/// or Make: a project that only builds through one of those is reported as
/// unsupported rather than silently mishandled.
class CToolchain implements Toolchain {
  const CToolchain();

  @override
  String get id => 'c';

  @override
  String get description =>
      'compiles C/C++ sources directly via zig cc or MinGW-w64';

  @override
  bool canHandle(Project project) => project.type == ProjectType.c;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(
          tool: 'zig',
          reason: 'cross-compiles C/C++ for windows/amd64 (zig cc / zig c++)',
          alternatives: ['x86_64-w64-mingw32-gcc', 'x86_64-w64-mingw32-g++'],
        ),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final sources = _discoverSources(request.project.root);
    if (sources.isEmpty) {
      return const BuildResult.failure(
        'no direct C/C++ sources found',
        details: 'WinBridge M1 compiles top-level and src/ *.c/*.cpp files '
            'directly; it does not drive CMake or Make. A project that '
            'builds only through CMakeLists.txt or a Makefile is not yet '
            'supported.',
      );
    }

    final isCpp = sources.any(
      (path) => _cxxExtensions.contains(p.extension(path)),
    );

    final compiler = request.tools.requireAny(
      isCpp
          ? ['zig', 'x86_64-w64-mingw32-g++']
          : ['zig', 'x86_64-w64-mingw32-gcc'],
      reason: 'cross-compiles C${isCpp ? '++' : ''} for windows/amd64',
    );

    final exe = p.join(request.outputDirectory, '${request.project.name}.exe');
    final isZig = compiler.name == 'zig';

    final result = await request.runner.run(
      compiler.path,
      [
        if (isZig) ...[isCpp ? 'c++' : 'cc', '-target', 'x86_64-windows-gnu'],
        if (request.mode.isRelease) '-O2',
        '-o', exe,
        ...request.extraArguments,
        ...sources,
      ],
      workingDirectory: request.project.root,
      environment: isZig
          ? {
              'ZIG_GLOBAL_CACHE_DIR': p.join(request.cacheDirectory, 'zig-cache'),
              'ZIG_LOCAL_CACHE_DIR':
                  p.join(request.cacheDirectory, 'zig-cache', 'local'),
            }
          : const {},
    );

    if (!result.ok) {
      return BuildResult.failure(
        '${isZig ? 'zig ${isCpp ? 'c++' : 'cc'}' : compiler.name} failed',
        details: result.diagnostics,
      );
    }

    return BuildResult.success(
      artifacts: [exe],
      summary: '${compiler.name}, windows/amd64',
      duration: result.duration,
    );
  }

  List<String> _discoverSources(String root) => discoverCSources(root);
}

/// Top-level and `src/` files ending in a recognized C/C++ extension, sorted so
/// argv order — and therefore build reproducibility — does not depend on
/// filesystem enumeration order.
///
/// Shared with the MSVC adapter: two C toolchains disagreeing about what counts
/// as a source file is the kind of drift nobody notices until one of them
/// quietly leaves a file out.
List<String> discoverCSources(String root) {
  final sources = <String>[
    ..._sourcesIn(root),
    ..._sourcesIn(p.join(root, 'src')),
  ];
  sources.sort();
  return sources;
}

/// Whether [sources] contains anything that has to be compiled as C++.
bool hasCxxSources(Iterable<String> sources) =>
    sources.any((path) => _cxxExtensions.contains(p.extension(path)));

List<String> _sourcesIn(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) return const [];
  return [
    for (final entry in dir.listSync())
      if (entry is File && _sourceExtensions.contains(p.extension(entry.path)))
        entry.path,
  ];
}
