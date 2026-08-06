@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_verifier.dart';
import 'package:winbridge/src/toolchains/go.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Builds `fixtures/hello_go` end to end through the real adapter and a real
/// `go` toolchain, and checks the artifact against the real PE verifier —
/// not fakes on either side. Skips cleanly when no `go` is on the resolver's
/// search path; CI bootstraps one so this always runs there.
void main() {
  final resolver = ToolResolver();
  final goAvailable = resolver.resolve('go') != null;

  test(
    'produces a windows/amd64 PE32+ executable that passes the PE verifier',
    () async {
      const go = GoToolchain();
      final projectRoot = p.join(Directory.current.path, 'fixtures', 'hello_go');
      final project = const ProjectDetector().detect(projectRoot);
      expect(project, isNotNull, reason: 'fixtures/hello_go should detect as Go');
      expect(project!.type, ProjectType.go);

      final result = await go.build(BuildRequest(
        project: project,
        outputDirectory: tempDir('go-integration-out'),
        cacheDirectory: tempDir('go-integration-cache'),
        runner: ProcessRunner(),
        tools: resolver,
        output: Output(out: StringBuffer(), err: StringBuffer()),
      ));

      expect(result.succeeded, isTrue, reason: result.failureMessage);
      expect(result.artifacts, isNotEmpty);
      expect(File(result.primaryArtifact!).existsSync(), isTrue);

      // The same verifier the CLI composes, run over the real binary.
      await expectLater(
        const PeVerifier().verify(result.primaryArtifact!),
        completes,
      );
    },
    skip: goAvailable ? false : 'go toolchain not found on the resolver search path',
  );
}
