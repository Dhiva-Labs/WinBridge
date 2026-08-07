import 'package:path/path.dart' as p;

/// Rewrites an absolute path that sits under [home] to start with `~`
/// instead, and leaves anything else untouched.
///
/// `winbridge report` is meant to be pasted into a public GitHub issue. A
/// path under `/home/<username>/...` would leak the reporter's account name
/// even though nothing else in the report does, so every path this module
/// prints goes through here first. [home] is whatever
/// `WinBridgeConfig.environment['HOME']` resolved to, which is already how
/// every such path was derived — this is exact-prefix replacement, not a
/// guess at where the user's home might be.
String redactHome(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  final normalizedHome = p.normalize(home);
  final normalizedPath = p.normalize(path);
  if (normalizedPath == normalizedHome) return '~';
  final withSlash =
      normalizedHome.endsWith('/') ? normalizedHome : '$normalizedHome/';
  if (normalizedPath.startsWith(withSlash)) {
    return '~/${normalizedPath.substring(withSlash.length)}';
  }
  return path;
}
