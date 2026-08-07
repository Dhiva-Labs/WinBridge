@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/package/installer_builder.dart';
import 'package:winbridge/src/package/nsis_script.dart';
import 'package:winbridge/src/pe/pe_header.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Really cross-compiles a program, really downloads NSIS, and really runs
/// `makensis.exe` under WinBridge's own Wine to produce an installer.
///
/// Skips when there is no Wine runtime — NSIS is only 2 MB but the engine that
/// runs it is not, and this suite does not download one.
void main() {
  final config = WinBridgeConfig();
  final resolver = ToolResolver(config: config);
  final quiet = Output(out: StringBuffer(), err: StringBuffer());

  final wine = WineRuntime(
    config: config,
    tools: resolver,
    runner: ProcessRunner(),
    output: quiet,
  ).resolve();
  final compiler = resolver.resolveAny(['zig', 'x86_64-w64-mingw32-gcc']);

  test(
    'builds a real NSIS installer from real artifacts',
    () async {
      final project = const ProjectDetector()
          .detect(p.join(Directory.current.path, 'fixtures', 'hello_c'));
      final artifacts = tempDir('package-artifacts');

      final build = await const CToolchain().build(BuildRequest(
        project: project!,
        outputDirectory: artifacts,
        cacheDirectory: tempDir('package-cache'),
        runner: ProcessRunner(),
        tools: resolver,
        output: quiet,
      ));
      expect(build.succeeded, isTrue, reason: build.failureMessage);

      final installerName = 'hello_c-9.9.9-setup.exe';
      final destination = p.join(artifacts, installerName);

      final installer = await InstallerBuilder(
        config: config,
        tools: resolver,
        runner: ProcessRunner(),
        output: quiet,
      ).buildDefaultInstaller(
        spec: InstallerSpec(
          appName: 'hello_c',
          version: '9.9.9',
          mainExecutable: build.primaryArtifact!,
          files: [build.primaryArtifact!],
          outputFile: installerName,
        ),
        workingDirectory: artifacts,
        destination: destination,
        wine: wine!,
      );

      expect(File(installer).existsSync(), isTrue);
      expect(File(installer).lengthSync(), greaterThan(10 * 1024));

      // A real Windows executable — and specifically a 32-bit one, which is
      // what NSIS emits so installers run on any Windows.
      final machine = validatePeImage(
        File(installer).readAsBytesSync(),
        label: p.basename(installer),
      );
      expect(describeMachine(machine), contains('i386'));
    },
    skip: wine == null
        ? 'no Wine runtime installed (run `winbridge run` once first)'
        : compiler == null
            ? 'no zig or mingw compiler to build the fixture with'
            : false,
  );
}
