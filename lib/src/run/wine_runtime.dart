import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import 'asset_cache.dart';

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
const pinnedWineBuild = PinnedAsset(
  name: 'wine-11.14-amd64-wow64',
  version: '11.14',
  url: 'https://github.com/Kron4ek/Wine-Builds/releases/download/11.14/'
      'wine-11.14-amd64-wow64.tar.xz',
  sha256: '707956fa1574ad1660c4d7f2cfd9c024e0f437ad0a2d501a53b717adb1288222',
  archiveTopLevel: 'wine-11.14-amd64-wow64',
);

/// The loader `run` invokes, inside a runtime directory. The wow64 build ships
/// a single `bin/wine` that handles both 32- and 64-bit Windows binaries;
/// there is no separate `wine64` to choose between.
String wineBinaryIn(String runtimeDirectory) =>
    p.join(runtimeDirectory, 'bin', 'wine');

/// `wineserver` beside a given `wine`, which is how Wine itself lays them out.
String wineserverBeside(String wineBinary) =>
    p.join(p.dirname(wineBinary), 'wineserver');

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

  /// The directory holding `wine`, which is also where `wineserver` and the
  /// rest of the tools live.
  String get binDirectory => p.dirname(binary);
}

/// Finds, and when asked installs, the Wine build `winbridge run` uses.
///
/// Resolution order, first hit wins:
///
///  1. `WINBRIDGE_WINE` — an explicit choice, used as given.
///  2. The managed runtime, but only if its install stamp records the checksum
///     this build is pinned to.
///  3. `wine` on the search path, via [ToolResolver].
class WineRuntime {
  WineRuntime({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
    this.build = pinnedWineBuild,
  }) : _cache = AssetCache(
          config: config,
          tools: tools,
          runner: runner,
          output: output,
        );

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;
  final PinnedAsset build;
  final AssetCache _cache;

  /// Kept as the one name callers and tests refer to; the rule it enforces
  /// lives in [AssetCache].
  static const stampFileName = AssetCache.stampFileName;

  String? get managedDirectory => _cache.directoryFor(build);

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
    if (managed != null &&
        _cache.isInstalled(build) &&
        _isExecutableFile(wineBinaryIn(managed))) {
      return ResolvedWine(
        binary: wineBinaryIn(managed),
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
        details: 'expected ${wineBinaryIn(target)}',
      );
    }
    return installed;
  }

  /// Downloads, verifies and unpacks the pinned build. See [AssetCache.install]
  /// for the ordering guarantees.
  Future<void> install() async {
    await _cache.install(build);
    final directory = managedDirectory;
    if (directory != null && !_isExecutableFile(wineBinaryIn(directory))) {
      throw BuildFailure(
        'the Wine archive has no runnable bin/wine',
        details: wineBinaryIn(directory),
      );
    }
  }

  static bool _isExecutableFile(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    return stat.mode & 0x49 != 0;
  }
}
