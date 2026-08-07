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

/// Redacts a path for publication: the home prefix becomes `~`, and the
/// account name is removed wherever else it appears.
///
/// [redactHome] alone is not enough, because not every path WinBridge reports
/// lives under `$HOME`. `WINBRIDGE_WINE=/opt/alice/wine` on a shared build
/// machine, a `vulkaninfo` found on a `PATH` entry under `/mnt/users/alice`,
/// or `XDG_CACHE_HOME` pointed outside the home directory all produce paths
/// that carry an account name straight into a report meant for a public issue.
///
/// Matching is on whole path segments, so a user called `bin` or `opt` does not
/// turn every path into redactions.
String redactPath(String path, String? home) =>
    _redactAccountName(redactHome(path, home), home);

String _redactAccountName(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  final account = p.basename(p.normalize(home));
  if (account.isEmpty || account == '.' || account == p.separator) {
    return path;
  }
  final segments = p.split(path);
  var redacted = false;
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] == account) {
      segments[i] = '<user>';
      redacted = true;
    }
  }
  return redacted ? p.joinAll(segments) : path;
}
