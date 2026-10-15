import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import '../run/asset_cache.dart';
import '../run/wine_runtime.dart';
import '../toolchains/msvc.dart';
import 'components.dart';

/// Runs `winbridge doctor --install <component>`.
///
/// Nothing here happens as a side effect of a build. Every one of these is a
/// download the user asked for, after being told how big it is and — for the
/// Microsoft SDK — what licence it carries.
class ComponentInstaller {
  ComponentInstaller({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
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
  final AssetCache _cache;

  /// The archive for this machine's CPU, or null when the component has none
  /// or cannot be used here at all. Components are never installed from another
  /// architecture's archive: an x86-64 compiler that cannot start is worse than
  /// no download.
  PinnedAsset? assetFor(InstallableComponent component) =>
      component.assetFor(config.hostArch);

  /// Why [component] cannot be installed on this host, or null when it can.
  ///
  /// Only things that need Wine are ruled out for a host the pinned Wine cannot
  /// run on, and only when no `WINBRIDGE_WINE` is set — with one, the user has
  /// said which Wine to use, and NSIS under it is as good as anywhere.
  WinBridgeException? unavailableReason(InstallableComponent component) {
    if (assetFor(component) == null) {
      return BuildFailure(
        '${component.id} has no download for this CPU',
        details: 'WinBridge pins ${component.id} for x86-64 and arm64 Linux '
            'only. Install it from your distribution and it is found on PATH.',
      );
    }
    if (component.needsWine &&
        !pinnedWineRunsOn(config.hostArch) &&
        config.wineOverride == null) {
      return wineUnavailableFailure(config.hostArch);
    }
    return null;
  }

  bool isInstalled(InstallableComponent component) {
    final asset = assetFor(component);
    return asset != null && _cache.isInstalled(asset);
  }

  /// Whether the component is fully usable, which for `msvc` means the
  /// Microsoft SDK is splatted too — the xwin binary on its own builds nothing.
  bool isComplete(InstallableComponent component) {
    if (!isInstalled(component)) return false;
    if (component.id != 'msvc') return true;
    final root = xwinSplatRoot(config);
    return root != null && XwinSplat(root).isPresent;
  }

  Future<void> install(InstallableComponent component) async {
    if (unavailableReason(component) case final reason?) throw reason;
    final asset = assetFor(component)!;

    if (component.licenceNote case final note?) {
      output.info('');
      output.info(note);
      output.info('');
    }
    output.info('Installing ${component.id} '
        '(${component.downloadSizeFor(config.hostArch)})');

    await _cache.install(asset);

    if (component.id == 'msvc') await _splatWindowsSdk(asset);

    final where = _cache.directoryFor(asset);
    output.info('Installed ${component.id}${where == null ? '' : ' into $where'}');
    if (component.followUp case final followUp?) {
      output.info(followUp);
    }
  }

  /// Downloads Microsoft's CRT and Windows SDK with xwin.
  ///
  /// `--accept-license` is passed because the user already saw the licence note
  /// and chose to run this; doing it silently at build time is exactly what
  /// this command exists to avoid.
  Future<void> _splatWindowsSdk(PinnedAsset xwinAsset) async {
    final splatRoot = xwinSplatRoot(config);
    if (splatRoot == null) {
      throw const BuildFailure(
        'cannot work out where to put the Windows SDK',
        details: 'no HOME or XDG_CACHE_HOME in the environment',
      );
    }

    final payload = _cache.payloadFor(xwinAsset);
    final xwin = p.join(payload!, 'xwin');
    if (!File(xwin).existsSync()) {
      throw BuildFailure('xwin is missing from its download', details: xwin);
    }

    output.info('Downloading the Microsoft CRT and Windows SDK into '
        '$splatRoot — this is the large part.');

    final result = await runner.run(
      xwin,
      [
        '--accept-license',
        '--cache-dir', p.join(splatRoot, '.xwin-cache'),
        'splat',
        '--output', splatRoot,
      ],
      streamOutput: true,
      captureOutput: false,
    );
    if (!result.ok) {
      throw BuildFailure(
        'xwin could not download the Windows SDK (exit ${result.exitCode})',
        details: 'Anything already downloaded is under $splatRoot and will be '
            'reused if you run this again.',
      );
    }
  }
}
