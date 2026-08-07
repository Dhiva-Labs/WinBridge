import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import '../detect/project.dart' show isSafeNameComponent;
import 'desktop_entry.dart';

/// Where desktop entries live: `$XDG_DATA_HOME/applications`, falling back to
/// `~/.local/share/applications` per the freedesktop base directory spec.
///
/// Deliberately not namespaced under `~/.local/share/winbridge` the way app
/// prefixes are: this directory is not WinBridge's private data, it is the
/// exact directory every desktop environment on the system already scans for
/// launcher entries.
String? applicationsDirectory(WinBridgeConfig config) {
  final env = config.environment;
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty && p.isAbsolute(xdg)) {
    return p.join(p.normalize(xdg), 'applications');
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty || !p.isAbsolute(home)) return null;
  return p.join(p.normalize(home), '.local', 'share', 'applications');
}

/// One entry `winbridge desktop list` can show.
class OwnedEntry {
  const OwnedEntry({
    required this.path,
    required this.name,
    required this.target,
  });

  final String path;
  final String name;

  /// The executable path pulled back out of `Exec=`.
  final String target;
}

/// Reads, writes, lists and removes the `.desktop` files WinBridge owns.
///
/// "Owns" is load-bearing. Every write goes through [DesktopEntry], and every
/// removal re-checks both the file name and the ownership marker immediately
/// before deleting — see [removeOwnedFile]. Nothing here ever globs a
/// directory and deletes what it finds: [list] only reads, and [remove]
/// deletes exactly one path it has already proven this tool owns.
class DesktopEntryStore {
  const DesktopEntryStore(this.config);

  final WinBridgeConfig config;

  String get directory {
    final dir = applicationsDirectory(config);
    if (dir == null) {
      throw const BuildFailure(
        'cannot work out where to install desktop entries',
        details: 'no HOME or XDG_DATA_HOME in the environment',
      );
    }
    return dir;
  }

  /// Writes [entry], refusing to overwrite a file at the same path that this
  /// tool did not create — re-running `add` for the same app updates its own
  /// entry, but a foreign file that happens to share the computed name is
  /// left alone.
  String write(DesktopEntry entry) {
    final dir = directory;
    Directory(dir).createSync(recursive: true);
    final path = p.join(dir, entry.fileName);
    final file = File(path);
    if (file.existsSync() && !_owns(file.readAsStringSync())) {
      throw UsageFailure(
        'refusing to overwrite $path',
        details: 'a file already exists there without a $ownershipMarker '
            'marker, so it was not created by winbridge — remove it '
            'yourself first if that is what you want',
      );
    }
    file.writeAsStringSync(entry.render());
    return path;
  }

  /// Every entry this tool owns, sorted by file name.
  List<OwnedEntry> list() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => _looksOwned(file.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final entries = <OwnedEntry>[];
    for (final file in files) {
      final content = file.readAsStringSync();
      if (!_owns(content)) continue;
      entries.add(OwnedEntry(
        path: file.path,
        name: _field(content, 'Name') ?? p.basenameWithoutExtension(file.path),
        target: _execTarget(content) ?? '',
      ));
    }
    return entries;
  }

  /// Removes the entry for [slugOrName]: the executable-stem slug first, and
  /// failing that an exact display-name match among the entries this tool
  /// owns. The argument must be a single safe path component — the same rule
  /// [DesktopEntry] applies to a display name, and what keeps a value like
  /// `../../etc/passwd` from ever reaching a path.
  void remove(String slugOrName) {
    if (!isSafeNameComponent(slugOrName)) {
      throw UsageFailure(
        'invalid desktop entry name: "$slugOrName"',
        details: 'run `winbridge desktop list` to see what exists',
      );
    }
    final slugPath = p.join(directory, 'winbridge-$slugOrName.desktop');
    if (File(slugPath).existsSync()) {
      removeOwnedFile(slugPath);
      return;
    }
    final byName =
        list().where((entry) => entry.name == slugOrName).toList();
    if (byName.length == 1) {
      removeOwnedFile(byName.single.path);
      return;
    }
    throw UsageFailure(
      byName.isEmpty
          ? 'no such desktop entry: $slugOrName'
          : 'more than one entry is named "$slugOrName"',
      details: 'run `winbridge desktop list` to see what exists',
    );
  }

  /// The strict check that makes deletion safe: [path]'s file name must
  /// start with `winbridge-` and end in `.desktop`, and its content must
  /// carry [ownershipMarker] — both checked immediately before the delete,
  /// not trusted from an earlier lookup.
  ///
  /// Exposed directly rather than reachable only through [remove], so the
  /// guard itself is unit-testable against any path — including ones
  /// [remove]'s own validation would never let through, which is exactly the
  /// defence-in-depth this module exists for.
  void removeOwnedFile(String path) {
    final name = p.basename(path);
    if (!name.startsWith('winbridge-') || !name.endsWith('.desktop')) {
      throw UsageFailure(
        'refusing to remove $path',
        details: 'file name does not look like one winbridge created',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageFailure('no such desktop entry: $path');
    }
    if (!_owns(file.readAsStringSync())) {
      throw UsageFailure(
        'refusing to remove $path',
        details: 'missing the $ownershipMarker marker — not something '
            'winbridge created',
      );
    }
    file.deleteSync();
  }

  bool _looksOwned(String path) {
    final name = p.basename(path);
    return name.startsWith('winbridge-') && name.endsWith('.desktop');
  }
}

bool _owns(String content) =>
    content.split('\n').map((line) => line.trim()).contains(ownershipMarker);

String? _field(String content, String key) {
  for (final line in content.split('\n')) {
    if (line.startsWith('$key=')) return line.substring(key.length + 1);
  }
  return null;
}

final _quotedArgument = RegExp(r'"((?:\\.|[^"\\])*)"');

/// The last quoted argument on the `Exec=` line — by construction, the
/// executable path — unescaped back to its original form. Only ever run
/// against content this store itself wrote, so a generic "backslash escapes
/// the next character" rule is exact, not merely a best effort.
String? _execTarget(String content) {
  final exec = _field(content, 'Exec');
  if (exec == null) return null;
  final matches = _quotedArgument.allMatches(exec).toList();
  if (matches.isEmpty) return null;
  final raw = matches.last.group(1)!;
  return raw.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);
}

/// Best-effort `update-desktop-database` refresh: most desktop environments
/// notice a new launcher file without it, and the ones that do not just fall
/// back to needing a re-login, so a missing tool or a non-zero exit is a
/// detail — logged in verbose mode — never something `add`/`remove` fails
/// over.
Future<void> refreshDesktopDatabase({
  required ToolResolver tools,
  required ProcessRunner runner,
  required String directory,
  required Output output,
}) async {
  final tool = tools.resolve('update-desktop-database');
  if (tool == null) {
    output.detail('update-desktop-database not found; skipping refresh');
    return;
  }
  final result = await runner.run(tool.path, [directory]);
  if (!result.ok) {
    output.detail(
      'update-desktop-database exited ${result.exitCode}: '
      '${result.diagnostics}',
    );
  }
}
