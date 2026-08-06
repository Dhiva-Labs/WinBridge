import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/artifact.dart';
import 'pe_header.dart';

/// Confirms a build artifact is a genuine PE32+ (x86-64) Windows image.
///
/// Only `.exe` and `.dll` artifacts are read — PDBs, bundles and other
/// adapter output pass through untouched. A toolchain does not get to vouch
/// for its own binary; this is the CLI's independent check that a
/// misconfigured cross-compiler did not hand back an ELF binary, a stray
/// script, or a truncated file.
class PeVerifier implements ArtifactVerifier {
  const PeVerifier();

  static const _checkedExtensions = {'.exe', '.dll'};

  @override
  String get name => 'PE32+ header';

  @override
  Future<void> verify(String artifactPath) async {
    final extension = p.extension(artifactPath).toLowerCase();
    if (!_checkedExtensions.contains(extension)) return;

    final bytes = await File(artifactPath).readAsBytes();
    validatePeHeader(bytes, label: p.basename(artifactPath));
  }
}
