import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/host_arch.dart';
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

/// Whether the pinned Wine build can execute on a machine of [arch].
///
/// It is an x86-64 program, so only an x64 host can start it. There is no
/// arm64 build of this pin: Kron4ek's Wine-Builds publish amd64 and x86 only,
/// and the arm64 options that do run x86-64 Windows programs (Hangover) are
/// per-distribution package bundles, not a portable archive WinBridge could
/// pin by checksum and unpack without root. So on any other host WinBridge
/// downloads nothing, rather than fetching a binary that cannot start.
bool pinnedWineRunsOn(HostArch? arch) => arch == HostArch.x64;

/// The failure `run`, `package`, `prefix tricks` and `recipe apply` raise on a
/// host the pinned Wine cannot run on, before anything is downloaded or any
/// prefix is created.
///
/// Honest about three things: what is wrong, what was deliberately not done
/// (no download, no PATH `wine` guessing), and the one way to proceed.
BuildFailure wineUnavailableFailure(HostArch? arch) {
  final machine = arch == null
      ? 'this CPU is neither x86-64 nor arm64'
      : 'this is an ${arch.slug} (${arch.machine}) machine';
  return BuildFailure(
    "cannot run Windows programs here: WinBridge's Wine is x86-64 only, and "
    '$machine',
    details: [
      'The managed Wine build (${pinnedWineBuild.name}) is an x86-64 program, '
          'so it cannot start on this CPU, and WinBridge has no pinned, '
          'checksum-verified Wine for this CPU that runs x86-64 Windows '
          'programs. Nothing was downloaded and no prefix was created.',
      '',
      'A `wine` found on PATH is not used automatically either: a Wine built '
          'natively for this CPU cannot run the x86-64 programs '
          '`winbridge build` produces without an x86-64 emulation layer.',
      '',
      'If you have a Wine that does run x86-64 Windows programs on this '
          'machine (a Hangover build, for example), set '
          '${WinBridgeConfig.wineVariable} to its `wine` binary and WinBridge '
          'will use it as given, without verifying it.',
      '',
      'Everything that does not need Wine works here: `winbridge build`, '
          '`detect`, `doctor`, `vm` and `report`.',
    ].join('\n'),
  );
}

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
///
/// Steps 2 and 3 apply only where the pinned build can run ([pinnedWineRunsOn],
/// x86-64 hosts). On any other host only step 1 can succeed: there is no build
/// to install, and a `wine` on PATH is an arm64 program that cannot run what
/// WinBridge builds, so using it would trade a clear message for loader noise.
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

  /// Whether this host can run the pinned build, and so whether the managed
  /// runtime and PATH lookup are on offer at all.
  bool get managedBuildSupported => pinnedWineRunsOn(config.hostArch);

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

    if (!managedBuildSupported) return null;

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

    if (!managedBuildSupported) throw wineUnavailableFailure(config.hostArch);

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
    if (!managedBuildSupported) throw wineUnavailableFailure(config.hostArch);
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
