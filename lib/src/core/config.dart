import 'dart:io';

import 'package:path/path.dart' as p;

import 'host_arch.dart';

/// Where WinBridge looks for things, and what it calls the things it makes.
///
/// This is declarative data only: names, directories, defaults. It never
/// carries a command to run. If an on-disk config file is added later it must
/// keep that property — no hooks, no scripts, no argv fragments that a project
/// can smuggle into a build.
class WinBridgeConfig {
  /// [hostArch] is the CPU architecture of this machine. It defaults to the
  /// one the process is running on; tests pass it explicitly so the arm64 code
  /// paths run on an x64 CI leg and the x64 ones on an arm64 leg.
  WinBridgeConfig({Map<String, String>? environment, HostArch? hostArch})
      : environment = Map.unmodifiable(environment ?? Platform.environment),
        hostArch = hostArch ?? HostArch.detect();

  /// The architecture of the machine WinBridge is running on, or null on a CPU
  /// it has no builds for. Everything that downloads a host binary (compilers,
  /// the xwin tool) or decides whether the pinned Wine can run keys off this.
  final HostArch? hostArch;

  /// Points at a directory of bootstrapped toolchains laid out the same way
  /// as the managed cache: `<dir>/<toolchain>/bin/<executable>`.
  static const toolchainDirVariable = 'WINBRIDGE_TOOLCHAIN_DIR';

  /// Absolute path to a `wine` binary that overrides everything WinBridge
  /// would otherwise find. For tests and for people who already run a Wine
  /// build they trust.
  static const wineVariable = 'WINBRIDGE_WINE';

  /// Build output lands here, relative to the project root, unless `--output`
  /// says otherwise. Under `build/` so the usual gitignore already covers it.
  static const defaultOutputDirectory = 'build/winbridge';

  final Map<String, String> environment;

  /// The `WINBRIDGE_WINE` override, if it is set to an absolute path.
  String? get wineOverride {
    final value = environment[wineVariable];
    if (value == null || value.isEmpty || !p.isAbsolute(value)) return null;
    return p.normalize(value);
  }

  /// The `WINBRIDGE_TOOLCHAIN_DIR` override, if it is set to an absolute path.
  String? get toolchainDirOverride {
    final value = environment[toolchainDirVariable];
    if (value == null || value.isEmpty || !p.isAbsolute(value)) return null;
    return p.normalize(value);
  }

  /// `~/.cache/winbridge`, honouring `XDG_CACHE_HOME`. Null when the
  /// environment gives us no home to work from.
  String? get cacheRoot {
    final xdg = environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty && p.isAbsolute(xdg)) {
      return p.join(p.normalize(xdg), 'winbridge');
    }
    final home = environment['HOME'];
    if (home == null || home.isEmpty || !p.isAbsolute(home)) return null;
    return p.join(p.normalize(home), '.cache', 'winbridge');
  }

  /// Root of the managed, no-sudo toolchain installs.
  String? get managedToolchainRoot {
    final root = cacheRoot;
    return root == null ? null : p.join(root, 'toolchains');
  }

  /// Scratch space handed to a toolchain so compilers keep their caches out of
  /// the project tree. One directory per toolchain id.
  String? buildCacheFor(String toolchainId) {
    final root = cacheRoot;
    return root == null ? null : p.join(root, 'build', toolchainId);
  }

  /// Root of the managed, no-sudo runtime installs — the Wine build
  /// `winbridge run` uses. A sibling of [managedToolchainRoot]: same cache,
  /// same no-root convention, and equally disposable. Deleting it costs a
  /// re-download and nothing else.
  String? get managedRuntimeRoot {
    final root = cacheRoot;
    return root == null ? null : p.join(root, 'runtimes');
  }

  /// `~/.local/share/winbridge`, honouring `XDG_DATA_HOME`.
  ///
  /// Separate from [cacheRoot] on purpose: a Wine prefix holds an installed
  /// app's own registry, configuration and saved files. That is user data, not
  /// a cache, and a tool that cleans caches must not take it.
  String? get dataRoot {
    final xdg = environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty && p.isAbsolute(xdg)) {
      return p.join(p.normalize(xdg), 'winbridge');
    }
    final home = environment['HOME'];
    if (home == null || home.isEmpty || !p.isAbsolute(home)) return null;
    return p.join(p.normalize(home), '.local', 'share', 'winbridge');
  }

  /// Where per-app Wine prefixes live, one directory per app.
  String? get prefixRoot {
    final root = dataRoot;
    return root == null ? null : p.join(root, 'prefixes');
  }
}
