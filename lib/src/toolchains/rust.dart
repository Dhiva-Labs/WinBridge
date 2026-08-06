import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/build.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';

const _rustTarget = 'x86_64-pc-windows-gnu';

/// Cross-compiles a Cargo project for the `windows-gnu` target. Cargo does
/// the compiling; the missing piece on a stock Linux box is the target's
/// standard library (added via `rustup target add`) and a mingw linker to
/// produce a PE image instead of an ELF one.
class RustToolchain implements Toolchain {
  const RustToolchain();

  @override
  String get id => 'rust';

  @override
  String get description => 'cross-compiles Rust via cargo --target $_rustTarget';

  @override
  bool canHandle(Project project) => project.type == ProjectType.rust;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(
          tool: 'cargo',
          reason: 'builds the $_rustTarget target',
        ),
        ToolRequirement(
          tool: 'x86_64-w64-mingw32-gcc',
          reason: 'links the windows-gnu target',
        ),
        ToolRequirement(
          tool: 'rustup',
          reason: 'installs the windows-gnu target when it is missing',
          optional: true,
        ),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final cargo = request.tools.requirePath(
      'cargo',
      reason: 'builds the $_rustTarget target',
    );
    request.tools.requirePath(
      'x86_64-w64-mingw32-gcc',
      reason: 'links the windows-gnu target',
    );

    final targetCheck = await _checkTargetInstalled(request);
    if (targetCheck != null) return targetCheck;

    final targetDir = p.join(request.cacheDirectory, 'cargo-target');
    // Cargo names the output directory after the profile, so a debug build
    // lands in `debug/` rather than `release/`.
    final profileDir = request.mode.isRelease ? 'release' : 'debug';

    final startedAt = DateTime.now();
    final result = await request.runner.run(
      cargo,
      [
        'build',
        if (request.mode.isRelease) '--release',
        '--target', _rustTarget,
        ...request.extraArguments,
      ],
      workingDirectory: request.project.root,
      environment: {'CARGO_TARGET_DIR': targetDir},
    );

    if (!result.ok) {
      return BuildResult.failure(
        'cargo build failed',
        details: result.diagnostics,
      );
    }

    final located = _locateExe(request, targetDir, profileDir, startedAt);
    if (located == null) {
      return BuildResult.failure(
        'cargo reported success but produced no .exe',
        details: 'looked in ${p.join(targetDir, _rustTarget, profileDir)}',
      );
    }

    final exe = p.join(request.outputDirectory, p.basename(located.path));
    located.copySync(exe);

    return BuildResult.success(
      artifacts: [exe],
      summary: 'rust, $_rustTarget',
      duration: result.duration,
    );
  }

  /// Runs `rustup target list --installed` when rustup is on the search
  /// path and fails fast with an actionable message if the windows-gnu
  /// target is missing. Returns null to mean "proceed with the build" —
  /// either the target is confirmed installed, or rustup is not available
  /// and cargo is left to report its own error.
  Future<BuildResult?> _checkTargetInstalled(BuildRequest request) async {
    final rustup = request.tools.resolve('rustup');
    if (rustup == null) return null;

    final installed = await request.runner.run(
      rustup.path,
      ['target', 'list', '--installed'],
    );
    if (!installed.ok) return null;
    if (installed.stdout.contains(_rustTarget)) return null;

    return const BuildResult.failure(
      'the $_rustTarget target is not installed',
      details: 'run: rustup target add $_rustTarget',
    );
  }

  /// The profile directory holds the final binaries directly; intermediate
  /// build products with hashed names live one level down in `deps/`, so a
  /// non-recursive listing is enough. Prefers a file named after the project,
  /// since Cargo accepts hyphens or underscores in a package name but keeps
  /// them as typed in the binary file name.
  ///
  /// [startedAt] guards against a stale binary: the target directory persists
  /// across builds, so a rename or a removed `[[bin]]` target can leave an old
  /// `.exe` behind that no longer corresponds to anything. Only files this
  /// build actually touched are eligible, and the remainder is sorted so the
  /// choice never depends on filesystem enumeration order.
  File? _locateExe(
    BuildRequest request,
    String targetDir,
    String profileDir,
    DateTime startedAt,
  ) {
    final outDir = Directory(p.join(targetDir, _rustTarget, profileDir));
    if (!outDir.existsSync()) return null;

    // A second of slack: cargo may hard-link an unchanged binary rather than
    // rewrite it, and filesystem timestamp granularity is not always finer.
    final floor = startedAt.subtract(const Duration(seconds: 1));
    final candidates = outDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.exe')
        .where((f) => !f.statSync().modified.isBefore(floor))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (candidates.isEmpty) return null;

    final name = request.project.name;
    final preferred = {
      '$name.exe',
      '${name.replaceAll('_', '-')}.exe',
      '${name.replaceAll('-', '_')}.exe',
    };
    for (final candidate in candidates) {
      if (preferred.contains(p.basename(candidate.path))) return candidate;
    }
    return candidates.first;
  }
}
