@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_launcher.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Cross-compiles `fixtures/hello_c` and actually runs the resulting `.exe`
/// under the managed Wine runtime, asserting what the program printed and the
/// code it exited with.
///
/// Skips rather than installs: the runtime is a ~94 MB download, so this only
/// runs where one is already present (`winbridge run` once locally, or a CI
/// job that caches `~/.cache/winbridge/runtimes`). It never reaches the
/// network itself.
void main() {
  final config = WinBridgeConfig();
  final resolver = ToolResolver(config: config);
  final runtime = WineRuntime(
    config: config,
    tools: resolver,
    runner: ProcessRunner(),
    output: Output(out: StringBuffer(), err: StringBuffer()),
  );

  final wine = runtime.resolve();
  final compiler = resolver.resolveAny(['zig', 'x86_64-w64-mingw32-gcc']);

  test(
    'runs a cross-compiled hello world and reports its output and exit code',
    () async {
      final projectRoot = p.join(Directory.current.path, 'fixtures', 'hello_c');
      final project = const ProjectDetector().detect(projectRoot);
      expect(project, isNotNull);

      final outputDirectory = tempDir('run-integration-out');
      final build = await const CToolchain().build(BuildRequest(
        project: project!,
        outputDirectory: outputDirectory,
        cacheDirectory: tempDir('run-integration-cache'),
        runner: ProcessRunner(),
        tools: resolver,
        output: Output(out: StringBuffer(), err: StringBuffer()),
      ));
      expect(build.succeeded, isTrue, reason: build.failureMessage);

      final exe = build.primaryArtifact!;
      expect(() => WineLauncher.checkExecutable(exe), returnsNormally);

      // A dedicated prefix rather than a throwaway one: creating a Wine
      // prefix from scratch takes minutes, and paying that on every `dart
      // test` would make the suite unusable. Named so it cannot collide with a
      // real app's, and safe to delete — the next run rebuilds it.
      final prefix = PrefixManager(config)
          .byName('winbridge_integration_test', flag: '--prefix');
      final captured = StringBuffer();

      final code = await WineLauncher(
        runner: ProcessRunner(
          output: Output(out: captured, err: StringBuffer()),
        ),
        output: Output(out: captured, err: StringBuffer()),
      ).launch(LaunchRequest(
        executable: exe,
        wine: wine!,
        prefix: prefix,
      ));

      expect(captured.toString(), contains('hello from winbridge'));
      expect(code, 0, reason: 'the app returns 0');
    },
    skip: wine == null
        ? 'no Wine runtime installed (run `winbridge run` once, or cache '
            '~/.cache/winbridge/runtimes in CI)'
        : compiler == null
            ? 'no zig or mingw compiler to build the fixture with'
            : false,
  );
}
