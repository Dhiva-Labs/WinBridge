import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A temporary directory that is removed when the current test ends.
///
/// The path is resolved, because `Directory.systemTemp` is a symlink on some
/// systems and tests compare paths against what the code under test resolved.
String tempDir([String prefix = 'winbridge']) {
  final directory = Directory.systemTemp.createTempSync('${prefix}_');
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  return directory.resolveSymbolicLinksSync();
}

String writeFile(String path, [String contents = '']) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
  return file.path;
}

/// A temp directory populated with [files], keyed by name relative to the root.
String projectDir(Map<String, String> files) {
  final root = tempDir('project');
  files.forEach((name, contents) => writeFile(p.join(root, name), contents));
  return root;
}

/// An executable file at `<directory>/<name>`.
///
/// Dart cannot chmod, and the test suite spawns no processes of its own, so the
/// executable bit comes from symlinking a system binary that already has one.
/// Only the path matters to the resolver; the target is never run.
String writeExecutable(String directory, String name) {
  Directory(directory).createSync(recursive: true);
  final path = p.join(directory, name);
  Link(path).createSync(_executableTarget);
  return path;
}

final String _executableTarget = ['/bin/true', '/usr/bin/true'].firstWhere(
  (candidate) => File(candidate).existsSync(),
  orElse: () => throw StateError('no system executable to link against'),
);

/// A `~/.cache/winbridge/toolchains/<toolchain>/bin` directory under [home].
String managedToolchainBin(String home, String toolchain) {
  final bin = p.join(home, '.cache', 'winbridge', 'toolchains', toolchain, 'bin');
  Directory(bin).createSync(recursive: true);
  return bin;
}
