@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/dxvk.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_launcher.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// Really downloads DXVK, really installs it into a real Wine prefix, and
/// really runs a cross-compiled executable with the DXVK overrides in place.
///
/// What this does *not* prove: that Direct3D rendering works. hello_c is a
/// console program and this machine has no verified Vulkan driver behind its
/// loader, so the rendering path is untested here — see docs/running.md, which
/// says so plainly rather than implying otherwise.
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
    'installs DXVK into a real prefix and still runs the app',
    () async {
      final project = const ProjectDetector()
          .detect(p.join(Directory.current.path, 'fixtures', 'hello_c'));
      final build = await const CToolchain().build(BuildRequest(
        project: project!,
        outputDirectory: tempDir('dxvk-out'),
        cacheDirectory: tempDir('dxvk-cache'),
        runner: ProcessRunner(),
        tools: resolver,
        output: quiet,
      ));
      expect(build.succeeded, isTrue, reason: build.failureMessage);
      final exe = build.primaryArtifact!;

      // Its own prefix, so enabling DXVK here cannot change how any real app
      // behaves. Reused between runs because building one takes minutes.
      final prefix = PrefixManager(config)
          .byName('winbridge_dxvk_test', flag: '--prefix');

      // Wine has to have built the prefix before DXVK has anywhere to go.
      final captured = StringBuffer();
      final launcher = WineLauncher(
        runner: ProcessRunner(output: Output(out: captured, err: captured)),
        output: Output(out: captured, err: captured),
      );
      await launcher.launch(
        LaunchRequest(executable: exe, wine: wine!, prefix: prefix),
      );

      await DxvkInstaller(
        config: config,
        tools: resolver,
        runner: ProcessRunner(),
        output: quiet,
      ).installInto(prefix);

      // The DLLs really landed where Wine will look for them.
      for (final dll in dxvkDlls) {
        expect(
          File(p.join(prefix.path, 'drive_c', 'windows', 'system32',
                  '$dll.dll'))
              .existsSync(),
          isTrue,
          reason: 'system32/$dll.dll',
        );
      }
      expect(DxvkInstaller.installedVersion(prefix), pinnedDxvk.version);

      // And the app still runs with the overrides set, which is the part that
      // would break loudly if the DLLs or the override string were wrong.
      final withDxvk = StringBuffer();
      final code = await WineLauncher(
        runner: ProcessRunner(output: Output(out: withDxvk, err: withDxvk)),
        output: Output(out: withDxvk, err: withDxvk),
      ).launch(LaunchRequest(
        executable: exe,
        wine: wine,
        prefix: prefix,
        dllOverrides: dxvkDllOverrides(),
      ));

      expect(withDxvk.toString(), contains('hello from winbridge'));
      expect(code, 0);
    },
    skip: wine == null
        ? 'no Wine runtime installed (run `winbridge run` once first)'
        : compiler == null
            ? 'no zig or mingw compiler to build the fixture with'
            : false,
  );
}
