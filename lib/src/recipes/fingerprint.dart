import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/winbridge.dart';

/// A fingerprint of one installer file: what a recipe's `match` block is
/// keyed against.
class InstallerFingerprint {
  const InstallerFingerprint({
    required this.sha256,
    required this.fileName,
    required this.sizeBytes,
  });

  /// Lowercase hex, 64 characters.
  final String sha256;

  final String fileName;
  final int sizeBytes;
}

/// Fingerprints the file at [path].
///
/// The hash is computed by shelling out to `sha256sum` through [runner] —
/// exactly how `AssetCache` verifies its own downloads (see
/// `lib/src/run/asset_cache.dart`) — rather than reading the file into Dart.
/// An installer can be hundreds of megabytes to several gigabytes; `sha256sum`
/// streams it a block at a time on its own side of the pipe, so this process
/// never holds more than a few bytes of the file's content at once.
Future<InstallerFingerprint> fingerprintFile(
  String path, {
  required ToolResolver tools,
  required ProcessRunner runner,
}) async {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.notFound) {
    throw UsageFailure('no such file: $path');
  }
  if (type != FileSystemEntityType.file) {
    throw UsageFailure('not a file: $path');
  }

  final sizeBytes = await File(path).length();

  final sha256sum = tools.requirePath(
    'sha256sum',
    reason: 'fingerprints installers for recipe matching',
  );
  final result = await runner.run(sha256sum, [path]);
  if (!result.ok) {
    throw ProcessFailure(
      result.commandLine,
      result.exitCode,
      output: result.diagnostics,
      what: 'sha256sum $path',
    );
  }

  final digest = result.stdout.trim().split(RegExp(r'\s+')).firstOrNull;
  if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw BuildFailure(
      'sha256sum produced unexpected output',
      details: result.stdout,
    );
  }

  return InstallerFingerprint(
    sha256: digest,
    fileName: p.basename(path),
    sizeBytes: sizeBytes,
  );
}
