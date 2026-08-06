import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_verifier.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Builds `fixtures/hello_c` end to end through the real adapter and a real
/// `zig cc`, and checks the artifact against the real PE verifier. Skips
/// cleanly when neither zig nor a mingw compiler is on the search path.
void main() {
  final resolver = ToolResolver();
  final compilerAvailable =
      resolver.resolveAny(['zig', 'x86_64-w64-mingw32-gcc']) != null;

  test(
    'produces a windows/amd64 PE32+ executable that passes the PE verifier',
    () async {
      const c = CToolchain();
      final projectRoot = p.join(Directory.current.path, 'fixtures', 'hello_c');
      final project = const ProjectDetector().detect(projectRoot);
      expect(project, isNotNull, reason: 'fixtures/hello_c should detect as C/C++');
      expect(project!.type, ProjectType.c);

      final result = await c.build(BuildRequest(
        project: project,
        outputDirectory: tempDir('c-integration-out'),
        cacheDirectory: tempDir('c-integration-cache'),
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
    skip: compilerAvailable
        ? false
        : 'neither zig nor x86_64-w64-mingw32-gcc found on the resolver search path',
  );
}
