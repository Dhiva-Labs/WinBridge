import 'dart:io';

import 'package:path/path.dart' as p;

/// Where WinBridge looks for things, and what it calls the things it makes.
///
/// This is declarative data only: names, directories, defaults. It never
/// carries a command to run. If an on-disk config file is added later it must
/// keep that property — no hooks, no scripts, no argv fragments that a project
/// can smuggle into a build.
class WinBridgeConfig {
  WinBridgeConfig({Map<String, String>? environment})
      : environment = Map.unmodifiable(environment ?? Platform.environment);

  /// Points at a directory of bootstrapped toolchains laid out the same way
  /// as the managed cache: `<dir>/<toolchain>/bin/<executable>`.
  static const toolchainDirVariable = 'WINBRIDGE_TOOLCHAIN_DIR';

  /// Build output lands here, relative to the project root, unless `--output`
  /// says otherwise. Under `build/` so the usual gitignore already covers it.
  static const defaultOutputDirectory = 'build/winbridge';

  final Map<String, String> environment;

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
}
