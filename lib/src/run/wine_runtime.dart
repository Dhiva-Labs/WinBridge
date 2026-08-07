import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';

/// The exact upstream Wine build WinBridge manages.
///
/// Pinned to one release from [Kron4ek/Wine-Builds](
/// https://github.com/Kron4ek/Wine-Builds) — portable builds that need no root
/// and no distro packages, which is what lets `winbridge run` work without the
/// user installing or configuring Wine at all.
///
/// The `wow64` variant is deliberate. The plain `amd64` build runs 32-bit
/// Windows apps only if the *host* has 32-bit glibc and friends installed
/// (`dpkg --add-architecture i386` and a pile of `:i386` packages); the wow64
/// build runs them from a pure 64-bit install with nothing added to the host.
/// Requiring a multilib setup would put Wine plumbing back in front of the
/// user, which is the thing this feature exists to remove.
class WineBuild {
  const WineBuild({
    required this.version,
    required this.name,
    required this.url,
    required this.sha256,
  });

  /// Upstream release, e.g. `11.14`.
  final String version;

  /// Directory name inside the archive and under the runtime root. Carrying
  /// the version means a new pin installs alongside the old one rather than
  /// overwriting a runtime that might be in use.
  final String name;

  final String url;

  /// Lowercase hex, verified before the archive is ever unpacked.
  final String sha256;

  /// The loader `run` invokes. The wow64 build ships a single `bin/wine` that
  /// handles both 32- and 64-bit Windows binaries; there is no separate
  /// `wine64` to choose between.
  String wineBinaryIn(String runtimeDirectory) =>
      p.join(runtimeDirectory, 'bin', 'wine');
}

const pinnedWineBuild = WineBuild(
  version: '11.14',
  name: 'wine-11.14-amd64-wow64',
  url: 'https://github.com/Kron4ek/Wine-Builds/releases/download/11.14/'
      'wine-11.14-amd64-wow64.tar.xz',
  sha256: '707956fa1574ad1660c4d7f2cfd9c024e0f437ad0a2d501a53b717adb1288222',
);

/// Where a resolved Wine came from. Drives what WinBridge is willing to claim
/// about it — only [managed] has had its bytes checked against a pin.
enum WineSource {
  /// `WINBRIDGE_WINE`, pointed at a binary by the user.
  override(WinBridgeConfig.wineVariable),

  /// The build WinBridge downloaded and verified itself.
  managed('managed runtime'),

  /// Whatever `wine` the search path turns up.
  system('PATH');

  const WineSource(this.label);

  final String label;
}

class ResolvedWine {
  const ResolvedWine({
    required this.binary,
    required this.source,
    this.runtimeDirectory,
  });

  /// Absolute path to the `wine` executable.
  final String binary;

  final WineSource source;

  /// Set only for [WineSource.managed].
  final String? runtimeDirectory;

  /// Whether WinBridge itself verified these bytes against [pinnedWineBuild].
  /// False for the two paths the user chose explicitly, which are trusted on
  /// their say-so rather than on a checksum.
  bool get isVerified => source == WineSource.managed;
}

/// Finds, and when asked installs, the Wine build `winbridge run` uses.
///
/// Resolution order, first hit wins:
///
///  1. `WINBRIDGE_WINE` — an explicit choice, used as given.
///  2. The managed runtime under `~/.cache/winbridge/runtimes/`, but only if
///     its install stamp records the checksum this build is pinned to.
///  3. `wine` on the search path, via [ToolResolver].
class WineRuntime {
  WineRuntime({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
    this.build = pinnedWineBuild,
  });

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;
  final WineBuild build;

  /// Written after a successful verified install; its presence *and* contents
  /// are what make a managed runtime usable. A half-extracted or hand-dropped
  /// directory has no stamp, so it is never run.
  static const stampFileName = '.winbridge-verified';

  String? get managedDirectory {
    final root = config.managedRuntimeRoot;
    return root == null ? null : p.join(root, build.name);
  }

  /// The already-usable Wine, or null when nothing is installed yet.
  ResolvedWine? resolve() {
    if (config.wineOverride case final override?) {
      if (_isExecutableFile(override)) {
        return ResolvedWine(binary: override, source: WineSource.override);
      }
      throw UsageFailure(
        '${WinBridgeConfig.wineVariable} does not point at an executable',
        details: override,
      );
    }

    final managed = managedDirectory;
    if (managed != null && _isInstalled(managed)) {
      return ResolvedWine(
        binary: build.wineBinaryIn(managed),
        source: WineSource.managed,
        runtimeDirectory: managed,
      );
    }

    final system = tools.resolve('wine');
    if (system != null) {
      return ResolvedWine(binary: system.path, source: WineSource.system);
    }
    return null;
  }

  /// [resolve], installing the pinned build first if nothing is available.
  Future<ResolvedWine> resolveOrInstall() async {
    final existing = resolve();
    if (existing != null) return existing;

    final target = managedDirectory;
    if (target == null) {
      throw const BuildFailure(
        'cannot work out where to install the Wine runtime',
        details: 'no HOME or XDG_CACHE_HOME in the environment',
      );
    }

    output.info('Installing the Wine runtime WinBridge uses to run Windows '
        'apps (${build.version}, ~94 MB) into $target');
    await install();

    final installed = resolve();
    if (installed == null) {
      throw BuildFailure(
        'the Wine runtime did not install correctly',
        details: 'expected ${build.wineBinaryIn(target)}',
      );
    }
    return installed;
  }

  /// Downloads, verifies and unpacks the pinned build.
  ///
  /// The checksum is checked before anything is unpacked — a mismatched
  /// archive is deleted, never opened. Extraction happens in a scratch
  /// directory beside the destination and is moved into place with a single
  /// rename, so a runtime directory either does not exist or is a complete,
  /// verified install; an interrupted download cannot leave a usable-looking
  /// half of one.
  Future<void> install() async {
    final root = config.managedRuntimeRoot;
    final target = managedDirectory;
    if (root == null || target == null) {
      throw const BuildFailure('no cache directory to install a runtime into');
    }

    final curl = tools.requirePath('curl', reason: 'downloads the Wine runtime');
    final tar = tools.requirePath('tar', reason: 'unpacks the Wine runtime');
    final sha256sum =
        tools.requirePath('sha256sum', reason: 'verifies the Wine runtime');

    Directory(root).createSync(recursive: true);
    // Beside the destination, not in /tmp: the final step is a rename, which
    // is only atomic within one filesystem.
    final scratch =
        Directory(p.join(root, '.install-${build.name}-$pid')).absolute;
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    scratch.createSync(recursive: true);

    try {
      final archive = p.join(scratch.path, 'wine.tar.xz');
      output.detail('downloading ${build.url}');
      final download = await runner.run(
        curl,
        [
          '-fL',
          '--silent',
          '--show-error',
          '--retry', '3',
          '--connect-timeout', '20',
          '-o', archive,
          build.url,
        ],
      );
      if (!download.ok) {
        throw BuildFailure(
          'could not download the Wine runtime',
          details: '${build.url}\n${download.diagnostics}'.trim(),
        );
      }

      await _verifyChecksum(sha256sum, archive);

      output.detail('unpacking into ${scratch.path}');
      final unpack = await runner.run(
        tar,
        ['-xJf', archive, '-C', scratch.path],
      );
      if (!unpack.ok) {
        throw BuildFailure(
          'could not unpack the Wine runtime',
          details: unpack.diagnostics,
        );
      }

      final unpacked = Directory(p.join(scratch.path, build.name));
      if (!unpacked.existsSync()) {
        throw BuildFailure(
          'the Wine archive did not contain ${build.name}/',
          details: 'downloaded from ${build.url}',
        );
      }
      if (!_isExecutableFile(build.wineBinaryIn(unpacked.path))) {
        throw BuildFailure(
          'the Wine archive has no runnable bin/wine',
          details: build.wineBinaryIn(unpacked.path),
        );
      }

      // Stamp before publishing, so the directory is never visible at its
      // final path without the proof that it was verified.
      File(p.join(unpacked.path, stampFileName))
          .writeAsStringSync('${build.name}\n${build.sha256}\n');

      final destination = Directory(target);
      if (destination.existsSync()) destination.deleteSync(recursive: true);
      unpacked.renameSync(target);
      output.detail('installed $target');
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  Future<void> _verifyChecksum(String sha256sum, String archive) async {
    final result = await runner.run(sha256sum, [archive]);
    // The digest is the first whitespace-separated field of the only line.
    final actual = result.stdout.trim().split(RegExp(r'\s+')).firstOrNull ?? '';
    if (!result.ok || actual.isEmpty) {
      _discard(archive);
      throw BuildFailure(
        'could not checksum the downloaded Wine runtime',
        details: result.diagnostics,
      );
    }
    if (actual.toLowerCase() != build.sha256.toLowerCase()) {
      _discard(archive);
      throw BuildFailure(
        'the downloaded Wine runtime does not match its expected checksum',
        details: 'expected ${build.sha256}\n'
            'got      ${actual.toLowerCase()}\n'
            'from     ${build.url}\n'
            'The download was discarded and nothing was unpacked.',
      );
    }
    output.detail('checksum verified: $actual');
  }

  static void _discard(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  /// A managed runtime counts as installed only with a stamp naming the
  /// checksum this build is pinned to, and a runnable loader beside it.
  bool _isInstalled(String directory) {
    final stamp = File(p.join(directory, stampFileName));
    if (!stamp.existsSync()) return false;
    if (!stamp.readAsStringSync().contains(build.sha256)) return false;
    return _isExecutableFile(build.wineBinaryIn(directory));
  }

  static bool _isExecutableFile(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    return stat.mode & 0x49 != 0;
  }
}
