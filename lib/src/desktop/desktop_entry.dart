import '../core/errors.dart';
import '../detect/project.dart' show isSafeNameComponent;

/// The line every entry this tool writes carries, and the only thing that
/// makes a `.desktop` file removable by `winbridge desktop remove`: without
/// it, a file is not something this tool created, however much its name
/// looks like one of ours.
const ownershipMarker = 'X-WinBridge=true';

const _icon = 'application-x-executable';
const _comment = 'Runs via WinBridge';

/// A validated, ready-to-write `.desktop` launcher entry.
///
/// Construction is where the security work happens — by the time a
/// [DesktopEntry] exists, [name] and [prefix] are both proven safe as a
/// single path-name component *and* as free text in a `.desktop` value, and
/// [render] never has to check anything again.
class DesktopEntry {
  DesktopEntry({
    required String slug,
    required String name,
    required String prefix,
    required this.executablePath,
  })  : slug = _validatedSlug(slug),
        name = _validated(name, what: 'name'),
        prefix = _validated(prefix, what: 'prefix name');

  /// The stable identity of this entry, derived from the executable's file
  /// stem — never from the display name, so `remove hello_c` works however
  /// the launcher label is spelled. Held to a stricter rule than [name]:
  /// also no spaces, since it becomes a file name and a desktop-file id.
  final String slug;

  /// Display text, written as `Name=`. Guaranteed by [isSafeNameComponent]
  /// to be free of path separators, control characters and newlines — a
  /// `name` of `evil\nExec=rm -rf ~` fails in the constructor and is never
  /// written.
  final String name;

  /// The `--prefix` value baked into `Exec=`. Same guarantee as [name].
  final String prefix;

  /// Absolute path to the target `.exe`. Not restricted to
  /// [isSafeNameComponent] — a real install path routinely has spaces and
  /// other characters a file-name component would reject — so it is instead
  /// quoted and escaped by [render] per the Desktop Entry "Quoting" rules.
  final String executablePath;

  /// The file-name component this entry is written under:
  /// `winbridge-<slug>.desktop`. The `winbridge-` prefix is what
  /// `winbridge desktop remove` checks before it will ever delete a file.
  String get fileName => 'winbridge-$slug.desktop';

  /// The full `.desktop` file content, terminated with a trailing newline.
  String render() => [
        '[Desktop Entry]',
        'Type=Application',
        'Name=$name',
        'Comment=$_comment',
        'Exec=${_execLine(prefix: prefix, executablePath: executablePath)}',
        'Icon=$_icon',
        'Terminal=false',
        'Categories=Utility;',
        'StartupNotify=false',
        ownershipMarker,
        '',
      ].join('\n');
}

/// Validates a value meant to become both a file-name component and a
/// `.desktop` `Name=`/`Comment=` line. The two turn out to be the same rule:
/// [isSafeNameComponent] already forbids control characters and newlines,
/// which is exactly what keeps an injected value from ever reaching a file.
String _validated(String value, {required String what}) {
  if (!isSafeNameComponent(value)) {
    throw UsageFailure(
      'invalid $what: "$value"',
      details: 'no path separators, control characters, newlines, or '
          '`* ? " < > | :`; and no leading `-`. Pass a different value.',
    );
  }
  return value;
}

/// A slug is a [_validated] value with one extra rule: no spaces, because it
/// becomes the `.desktop` file's name and therefore the entry's id.
String _validatedSlug(String value) {
  final checked = _validated(value, what: 'entry id');
  if (checked.contains(' ')) {
    throw UsageFailure(
      'invalid entry id: "$value"',
      details: 'an entry id is derived from the executable file name and '
          'cannot contain spaces',
    );
  }
  return checked;
}

/// Escapes one `Exec=` argument per the Desktop Entry Specification's
/// "Quoting" rules — backslash, double quote, backtick and dollar sign are
/// escaped with a preceding backslash — and always wraps the result in
/// double quotes. Quoting unconditionally, rather than only when a reserved
/// character is present, means a value that later grows one (a path moved
/// under a directory with a space in it) never needs re-deriving the rule.
String quoteExecArgument(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$');
  return '"$escaped"';
}

String _execLine({required String prefix, required String executablePath}) =>
    'winbridge run --prefix ${quoteExecArgument(prefix)} '
    '${quoteExecArgument(executablePath)}';
