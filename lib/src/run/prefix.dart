import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../detect/project.dart' show isSafeNameComponent;

/// One app's Wine prefix: its private C: drive, registry and installed state.
///
/// One per app rather than one shared prefix, so installing something that
/// wants an old runtime, or an app that corrupts its own registry, cannot
/// reach any other app. Resetting an app is `rm -rf` on its prefix directory
/// and nothing else — there is no other state to clean up.
class AppPrefix {
  const AppPrefix({required this.name, required this.path});

  final String name;

  /// Absolute path, used as `WINEPREFIX`.
  final String path;

  bool get exists => Directory(path).existsSync();
}

/// Names and locates prefixes. Naming is the security-relevant half: the
/// default comes from a file name on disk, and `--prefix` comes from the
/// command line, so both go through the same check that keeps a prefix inside
/// the prefix root.
class PrefixManager {
  const PrefixManager(this.config);

  final WinBridgeConfig config;

  String get _root {
    final root = config.prefixRoot;
    if (root == null) {
      throw const BuildFailure(
        'cannot work out where to keep app prefixes',
        details: 'no HOME or XDG_DATA_HOME in the environment',
      );
    }
    return root;
  }

  /// The prefix for [name], which must be a single safe path component.
  AppPrefix byName(String name, {required String flag}) {
    if (!isSafeNameComponent(name)) {
      throw UsageFailure(
        'invalid prefix name: "$name"',
        details: 'a prefix name is one path component: letters, digits, '
            '`.`, `-`, `_`; no separators, no leading dash. '
            'Pass a different $flag.',
      );
    }
    return AppPrefix(name: name, path: p.join(_root, name));
  }

  /// The default prefix for an executable: its file name without the
  /// extension, so `Setup.exe` and `game.exe` get their own worlds.
  ///
  /// A name that is not a usable path component is refused rather than
  /// mangled into one — the user is right there and can pass `--prefix`.
  AppPrefix forExecutable(String executablePath) {
    final stem = p.basenameWithoutExtension(executablePath);
    if (!isSafeNameComponent(stem)) {
      throw UsageFailure(
        'cannot derive a prefix name from "${p.basename(executablePath)}"',
        details: 'pass --prefix <name> to choose one',
      );
    }
    return byName(stem, flag: '--prefix');
  }

  /// Every prefix that exists, by name.
  List<AppPrefix> list() {
    final root = config.prefixRoot;
    if (root == null || !Directory(root).existsSync()) return const [];
    final names = [
      for (final entry in Directory(root).listSync(followLinks: false))
        if (entry is Directory) p.basename(entry.path),
    ]..sort();
    return [
      for (final name in names) AppPrefix(name: name, path: p.join(root, name)),
    ];
  }
}
