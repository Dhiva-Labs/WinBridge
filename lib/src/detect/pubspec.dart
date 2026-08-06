/// Just enough of a pubspec to tell a Flutter app from a plain Dart package.
///
/// Deliberately not a YAML parser. Detection needs two facts — the package name
/// and whether Flutter is involved — and a hand-rolled line scan keeps a YAML
/// dependency out of the CLI. A malformed pubspec here means "not detected",
/// never a crash.
class Pubspec {
  const Pubspec({required this.name, required this.usesFlutter});

  final String? name;
  final bool usesFlutter;

  static final _name = RegExp(r'^name:\s*(?:"([^"]*)"|' r"'([^']*)'|(\S+))\s*$");
  static final _topLevelKey = RegExp(r'^([A-Za-z_][\w-]*):');
  static final _flutterEntry = RegExp(r'^\s+flutter:\s*$');
  static final _flutterSdk = RegExp(r'^\s*sdk:\s*flutter\s*$');

  static const _dependencyBlocks = {
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  };

  static Pubspec parse(String source) {
    String? name;
    var usesFlutter = false;
    String? block;

    for (final raw in source.split('\n')) {
      final line = _stripComment(raw.replaceAll('\r', ''));
      if (line.trim().isEmpty) continue;

      final topLevel = _topLevelKey.firstMatch(line);
      if (topLevel != null) {
        block = topLevel.group(1);
        // A top-level `flutter:` section is the asset/plugin config block, and
        // only a Flutter project has one.
        if (block == 'flutter') usesFlutter = true;
        final nameMatch = _name.firstMatch(line);
        if (nameMatch != null) {
          name = nameMatch.group(1) ?? nameMatch.group(2) ?? nameMatch.group(3);
        }
        continue;
      }

      if (block != null && _dependencyBlocks.contains(block)) {
        // `flutter:` nested under a dependency block, with or without the
        // `sdk: flutter` line beneath it.
        if (_flutterEntry.hasMatch(line)) usesFlutter = true;
      }
      if (_flutterSdk.hasMatch(line)) usesFlutter = true;
    }

    return Pubspec(name: name, usesFlutter: usesFlutter);
  }

  static String _stripComment(String line) {
    final index = line.indexOf('#');
    if (index < 0) return line;
    if (index == 0) return '';
    // Only treat `#` as a comment when it follows whitespace, so values such as
    // a colour literal survive.
    if (line[index - 1] == ' ' || line[index - 1] == '\t') {
      return line.substring(0, index);
    }
    return line;
  }
}
