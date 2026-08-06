import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_verifier.dart';
import 'package:winbridge/src/toolchains/rust.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Builds `fixtures/hello_rust` end to end through the real adapter. Skips
/// cleanly — via [ToolResolver], not a hardcoded assumption — when cargo or
/// the windows-gnu linker is missing locally; CI runs the full matrix.
void main() {
  final resolver = ToolResolver();
  final cargoAvailable = resolver.resolve('cargo') != null &&
      resolver.resolve('x86_64-w64-mingw32-gcc') != null;

  test(
    'produces a windows/amd64 PE32+ executable that passes the PE verifier',
    () async {
      const rust = RustToolchain();
      final projectRoot = p.join(Directory.current.path, 'fixtures', 'hello_rust');
      final project = const ProjectDetector().detect(projectRoot);
      expect(project, isNotNull, reason: 'fixtures/hello_rust should detect as Rust');
      expect(project!.type, ProjectType.rust);

      final result = await rust.build(BuildRequest(
        project: project,
        outputDirectory: tempDir('rust-integration-out'),
        cacheDirectory: tempDir('rust-integration-cache'),
        runner: ProcessRunner(),
        tools: resolver,
        output: Output(out: StringBuffer(), err: StringBuffer()),
      ));

      expect(result.succeeded, isTrue, reason: result.failureMessage);
      expect(result.artifacts, isNotEmpty);
      expect(File(result.primaryArtifact!).existsSync(), isTrue);

      await expectLater(
        const PeVerifier().verify(result.primaryArtifact!),
        completes,
      );
    },
    skip: cargoAvailable
        ? false
        : 'cargo or the x86_64-w64-mingw32-gcc linker not found locally',
  );
}
