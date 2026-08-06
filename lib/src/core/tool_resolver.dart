import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'errors.dart';

/// Which part of the search order produced a tool.
enum ToolSource {
  override(WinBridgeConfig.toolchainDirVariable),
  managed('managed toolchains'),
  path('PATH');

  const ToolSource(this.label);

  final String label;
}

/// A directory on the search path, and why it is there.
class ToolSearchEntry {
  const ToolSearchEntry(this.directory, this.source);

  final String directory;
  final ToolSource source;
}

class ResolvedTool {
  const ResolvedTool({
    required this.name,
    required this.path,
    required this.source,
  });

  final String name;

  /// Absolute path to the executable.
  final String path;

  final ToolSource source;

  @override
  String toString() => path;
}

/// Finds executables without requiring anything to be installed system-wide.
///
/// Search order, first hit wins:
///
///   1. `WINBRIDGE_TOOLCHAIN_DIR`, expanded to its `*/bin` subdirectories.
///   2. `~/.cache/winbridge/toolchains/*/bin` — the managed, no-sudo installs.
///   3. `PATH`, in its own order.
///
/// Managed installs deliberately outrank `PATH`: a developer who bootstrapped
/// a pinned toolchain into their cache gets that one, not whatever an unrelated
/// system package happens to provide.
class ToolResolver {
  ToolResolver({WinBridgeConfig? config, Map<String, String>? environment})
      : _config = config ?? WinBridgeConfig(environment: environment);

  final WinBridgeConfig _config;
  final Map<String, ResolvedTool?> _cache = {};

  late final List<ToolSearchEntry> searchEntries = _buildSearchPath();

  List<String> get searchDirectories =>
      [for (final entry in searchEntries) entry.directory];

  /// Absolute path to [name], or null when it is nowhere on the search path.
  ResolvedTool? resolve(String name) {
    if (name.isEmpty || name.contains('/') || name == '.' || name == '..') {
      throw ArgumentError.value(
        name,
        'name',
        'expected a bare executable name, not a path',
      );
    }
    return _cache.putIfAbsent(name, () {
      for (final entry in searchEntries) {
        final candidate = p.join(entry.directory, name);
        if (_isExecutableFile(candidate)) {
          return ResolvedTool(
            name: name,
            path: p.normalize(candidate),
            source: entry.source,
          );
        }
      }
      return null;
    });
  }

  /// First of [names] that resolves. Used where a requirement has more than one
  /// acceptable provider, such as zig cc or MinGW for the C toolchain.
  ResolvedTool? resolveAny(Iterable<String> names) {
    for (final name in names) {
      final found = resolve(name);
      if (found != null) return found;
    }
    return null;
  }

  /// Like [resolve] but throws [ToolNotFound] instead of returning null.
  String requirePath(String name, {String? reason}) =>
      requireAny([name], reason: reason).path;

  ResolvedTool requireAny(List<String> names, {String? reason}) {
    final found = resolveAny(names);
    if (found != null) return found;
    throw ToolNotFound(names, searchDirectories, reason: reason);
  }

  List<ToolSearchEntry> _buildSearchPath() {
    final entries = <ToolSearchEntry>[];
    final seen = <String>{};

    void add(String directory, ToolSource source) {
      final normalized = p.normalize(directory);
      if (!p.isAbsolute(normalized) || !seen.add(normalized)) return;
      entries.add(ToolSearchEntry(normalized, source));
    }

    final override = _config.toolchainDirOverride;
    if (override != null) {
      for (final bin in _binDirectoriesUnder(override)) {
        add(bin, ToolSource.override);
      }
    }

    final managed = _config.managedToolchainRoot;
    if (managed != null) {
      for (final bin in _binDirectoriesUnder(managed)) {
        add(bin, ToolSource.managed);
      }
    }

    for (final directory in (_config.environment['PATH'] ?? '').split(':')) {
      // Relative PATH entries resolve against the current directory, which is
      // whatever the user happened to `cd` into. Never search those.
      if (directory.isEmpty || !p.isAbsolute(directory)) continue;
      add(directory, ToolSource.path);
    }

    return List.unmodifiable(entries);
  }

  /// `<root>/*/bin`, sorted so the search order does not depend on the order
  /// the filesystem hands back directory entries.
  List<String> _binDirectoriesUnder(String root) {
    final directory = Directory(root);
    if (!directory.existsSync()) return const [];
    final bins = <String>[];
    for (final child in directory.listSync().whereType<Directory>()) {
      final bin = p.join(child.path, 'bin');
      if (Directory(bin).existsSync()) bins.add(bin);
    }
    bins.sort();
    return bins;
  }

  static bool _isExecutableFile(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    return stat.mode & 0x49 != 0; // any of user/group/other execute
  }
}
