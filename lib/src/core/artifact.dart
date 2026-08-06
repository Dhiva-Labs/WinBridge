import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'paths.dart';

/// An extra check applied to a build artifact once it has passed the path
/// rules below.
///
/// `lib/src/pe/` provides the M1 implementation, which reads the PE32+ header
/// and refuses anything that is not a Windows executable — so `winbridge build`
/// cannot report success over an ELF binary a misconfigured cross-compiler
/// happened to emit. Verifiers are composed by the CLI, never by adapters: a
/// toolchain does not get to vouch for its own output.
abstract class ArtifactVerifier {
  /// Shown in verbose output, e.g. `PE32+ header`.
  String get name;

  /// Throws [ArtifactFailure] if [artifactPath] does not pass.
  Future<void> verify(String artifactPath);
}

/// Validates every path a toolchain claims to have produced.
///
/// The rules are the same for a local cross-compiler and for a path that
/// arrived over SSH from a Windows VM: absolute, existing, a regular file, and
/// strictly inside the output directory once symlinks are resolved. A build is
/// only a success after this passes.
Future<List<String>> verifyArtifacts(
  List<String> artifacts, {
  required String outputDirectory,
  List<ArtifactVerifier> verifiers = const [],
}) async {
  if (artifacts.isEmpty) {
    throw const ArtifactFailure(
      'the toolchain reported success but produced no artifacts',
    );
  }

  final verified = <String>[];
  for (final artifact in artifacts) {
    requireInside(
      parent: outputDirectory,
      child: artifact,
      what: 'artifact ${p.basename(artifact)}',
    );
    if (FileSystemEntity.typeSync(artifact) != FileSystemEntityType.file) {
      throw ArtifactFailure(
        'artifact was not produced: ${p.basename(artifact)}',
        details: artifact,
      );
    }
    for (final verifier in verifiers) {
      await verifier.verify(artifact);
    }
    verified.add(realPath(artifact));
  }
  return verified;
}
