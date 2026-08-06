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

    final result = await request.runner.run(
      cargo,
      [
        'build',
        '--release',
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

    final located = _locateExe(request, targetDir);
    if (located == null) {
      return BuildResult.failure(
        'cargo reported success but produced no .exe',
        details: 'looked in '
            '${p.join(targetDir, _rustTarget, 'release')}',
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

  /// The release directory holds the final binaries directly; intermediate
  /// build products with hashed names live one level down in `deps/`, so a
  /// non-recursive listing is enough. Prefers a file named after the
  /// project, since Cargo accepts hyphens or underscores in a package name
  /// but keeps them as typed in the binary file name.
  File? _locateExe(BuildRequest request, String targetDir) {
    final releaseDir = Directory(p.join(targetDir, _rustTarget, 'release'));
    if (!releaseDir.existsSync()) return null;

    final candidates = releaseDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.exe')
        .toList();
    if (candidates.isEmpty) return null;

    final name = request.project.name;
    final preferred = {'$name.exe', '${name.replaceAll('_', '-')}.exe',
        '${name.replaceAll('-', '_')}.exe'};
    return candidates.firstWhere(
      (f) => preferred.contains(p.basename(f.path)),
      orElse: () => candidates.first,
    );
  }
}
