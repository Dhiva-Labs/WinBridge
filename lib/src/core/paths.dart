import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// Absolute, normalized, symlink-free form of [path].
///
/// Symlinks are resolved so that containment checks cannot be defeated by a
/// link pointing out of the directory being guarded. Paths that do not exist
/// yet are normalized but obviously cannot be resolved further.
String realPath(String path) {
  final absolute = p.canonicalize(path);
  if (!FileSystemEntity.typeSync(absolute).isFile(orDirectory: true)) {
    return absolute;
  }
  try {
    return p.canonicalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

/// Whether [child] sits strictly beneath [parent] once both are resolved.
bool isInside(String parent, String child) =>
    p.isWithin(realPath(parent), realPath(child));

/// Throws unless [child] sits strictly beneath [parent].
///
/// Every path that arrives from outside the CLI — a toolchain's reported
/// artifact, a file listed in a VM's build manifest, anything read from
/// config — passes through here before it is used.
void requireInside({
  required String parent,
  required String child,
  required String what,
}) {
  if (!p.isAbsolute(child)) {
    throw ArtifactFailure(
      '$what is not an absolute path: $child',
      details: 'paths crossing a module boundary must be absolute',
    );
  }
  if (!isInside(parent, child)) {
    throw ArtifactFailure(
      '$what escapes the output directory',
      details: 'path:   $child\nallowed under: $parent',
    );
  }
}

extension on FileSystemEntityType {
  bool isFile({bool orDirectory = false}) =>
      this == FileSystemEntityType.file ||
      (orDirectory && this == FileSystemEntityType.directory);
}
