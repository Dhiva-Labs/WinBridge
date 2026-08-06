import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_verifier.dart';
import 'package:winbridge/src/toolchains/dotnet.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Builds `fixtures/hello_dotnet` end to end through the real adapter. Skips
/// cleanly — via [ToolResolver], not a hardcoded assumption — when the
/// `dotnet` SDK is missing locally; CI runs the full matrix.
void main() {
  final resolver = ToolResolver();
  final dotnetAvailable = resolver.resolve('dotnet') != null;

  test(
    'produces a windows/amd64 PE32+ apphost that passes the PE verifier',
    () async {
      const dotnet = DotnetToolchain();
      final projectRoot = p.join(Directory.current.path, 'fixtures', 'hello_dotnet');
      final project = const ProjectDetector().detect(projectRoot);
      expect(project, isNotNull, reason: 'fixtures/hello_dotnet should detect as .NET');
      expect(project!.type, ProjectType.dotnet);

      final result = await dotnet.build(BuildRequest(
        project: project,
        outputDirectory: tempDir('dotnet-integration-out'),
        cacheDirectory: tempDir('dotnet-integration-cache'),
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
    skip: dotnetAvailable ? false : 'dotnet SDK not found on the resolver search path',
  );
}
