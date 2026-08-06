import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/toolchains/rust.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support.dart';

void main() {
  const rust = RustToolchain();

  late String home;
  late String pathDir;
  late String output;
  late String cache;
  late String projectRoot;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    output = tempDir('out');
    cache = tempDir('cache');
    projectRoot = projectDir({
      'Cargo.toml': '[package]\nname = "hello_rust"\nversion = "0.1.0"\n',
    });
  });

  ToolResolver resolver() =>
      ToolResolver(environment: {'HOME': home, 'PATH': pathDir});

  Project project() => Project(
        root: projectRoot,
        type: ProjectType.rust,
        name: 'hello_rust',
        evidence: const [
          DetectionEvidence(
              type: ProjectType.rust, file: 'Cargo.toml', reason: 'cargo manifest'),
        ],
      );

  BuildRequest request({
    required ProcessRunner runner,
    ToolResolver? tools,
    List<String> extraArguments = const [],
    BuildMode mode = BuildMode.release,
  }) =>
      BuildRequest(
        project: project(),
        outputDirectory: output,
        cacheDirectory: cache,
        runner: runner,
        tools: tools ?? resolver(),
        output: silentOutput(),
        extraArguments: extraArguments,
        mode: mode,
      );

  /// Cargo actually writing the .exe is what a real build does; the fake
  /// runner never spawns cargo, so tests that exercise the "locate the
  /// output" step create it themselves at the path cargo would have used.
  String plantExe(String name, {String profile = 'release'}) {
    final dir = p.join(cache, 'cargo-target', 'x86_64-pc-windows-gnu', profile);
    return writeFile(p.join(dir, name), 'stub-pe-bytes');
  }

  test('id and description', () {
    expect(rust.id, 'rust');
    expect(rust.description, contains('windows-gnu'));
  });

  group('canHandle', () {
    test('claims Rust projects', () {
      expect(rust.canHandle(fakeProject(ProjectType.rust)), isTrue);
    });

    test('ignores everything else', () {
      for (final type in ProjectType.values.where((t) => t != ProjectType.rust)) {
        expect(rust.canHandle(fakeProject(type)), isFalse);
      }
    });
  });

  test('requirements: cargo and a mingw linker required, rustup optional', () {
    final requirements = rust.requirements();
    final byTool = {for (final r in requirements) r.tool: r};

    expect(byTool['cargo']!.optional, isFalse);
    expect(byTool['x86_64-w64-mingw32-gcc']!.optional, isFalse);
    expect(byTool['rustup']!.optional, isTrue);
  });

  group('build', () {
    test('missing cargo propagates ToolNotFound', () {
      final runner = RecordingProcessRunner();
      expect(() => rust.build(request(runner: runner)), throwsA(isA<ToolNotFound>()));
    });

    test('missing mingw linker propagates ToolNotFound even with cargo present', () {
      writeExecutable(pathDir, 'cargo');
      final runner = RecordingProcessRunner();
      expect(() => rust.build(request(runner: runner)), throwsA(isA<ToolNotFound>()));
    });

    test('argv: cargo build --release --target x86_64-pc-windows-gnu, extra args appended', () async {
      final cargoPath = writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      plantExe('hello_rust.exe');
      final runner = RecordingProcessRunner();

      await rust.build(request(runner: runner, extraArguments: ['--locked']));

      final call = runner.calls.single;
      expect(call.executable, cargoPath);
      expect(call.arguments, [
        'build',
        '--release',
        '--target', 'x86_64-pc-windows-gnu',
        '--locked',
      ]);
      expect(call.environment, {
        'CARGO_TARGET_DIR': p.join(cache, 'cargo-target'),
      });
      expect(call.workingDirectory, projectRoot);
    });

    test('copies the located .exe into the output directory', () async {
      writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      plantExe('hello_rust.exe');
      final runner = RecordingProcessRunner();

      final result = await rust.build(request(runner: runner));

      expect(result.succeeded, isTrue);
      final exe = p.join(output, 'hello_rust.exe');
      expect(result.artifacts, [exe]);
      expect(File(exe).readAsStringSync(), 'stub-pe-bytes');
    });

    test('a hyphenated binary name is still found', () async {
      writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      plantExe('hello-rust.exe');
      final runner = RecordingProcessRunner();

      final result = await rust.build(request(runner: runner));

      expect(result.succeeded, isTrue);
      expect(result.artifacts.single, p.join(output, 'hello-rust.exe'));
    });

    test('cargo exiting non-zero is a failure, not a throw', () async {
      writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(stderr: 'error[E0433]'),
      );

      final result = await rust.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('cargo build failed'));
      expect(result.details, contains('E0433'));
    });

    test('cargo succeeding without an .exe is a clean failure', () async {
      writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      final runner = RecordingProcessRunner();

      final result = await rust.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no .exe'));
    });

    group('rustup target check', () {
      test('skipped when rustup is not on the search path', () async {
        writeExecutable(pathDir, 'cargo');
        writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
        plantExe('hello_rust.exe');
        final runner = RecordingProcessRunner();

        final result = await rust.build(request(runner: runner));

        expect(result.succeeded, isTrue);
        expect(runner.calls, hasLength(1), reason: 'only cargo build should run');
      });

      test('fails fast with an actionable message when the target is missing', () async {
        writeExecutable(pathDir, 'cargo');
        writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
        final rustupPath = writeExecutable(pathDir, 'rustup');
        final runner = RecordingProcessRunner(
          onRun: (call) => call.executable == rustupPath
              ? okResult(stdout: 'x86_64-unknown-linux-gnu (default)\n')
              : null,
        );

        final result = await rust.build(request(runner: runner));

        expect(result.succeeded, isFalse);
        expect(result.failureMessage, contains('not installed'));
        expect(result.details, contains('rustup target add x86_64-pc-windows-gnu'));
        expect(runner.calls, hasLength(1), reason: 'cargo build should not run');
      });

      test('proceeds when rustup confirms the target is installed', () async {
        writeExecutable(pathDir, 'cargo');
        writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
        final rustupPath = writeExecutable(pathDir, 'rustup');
        plantExe('hello_rust.exe');
        final runner = RecordingProcessRunner(
          onRun: (call) => call.executable == rustupPath
              ? okResult(stdout: 'x86_64-pc-windows-gnu\n')
              : null,
        );

        final result = await rust.build(request(runner: runner));

        expect(result.succeeded, isTrue);
        expect(runner.calls, hasLength(2));
      });
    });

    group('build mode', () {
      test('--debug drops --release and reads the debug profile dir', () async {
        writeExecutable(pathDir, 'cargo');
        writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
        final planted = plantExe('hello_rust.exe', profile: 'debug');
        final runner = RecordingProcessRunner();

        final result = await rust.build(
          request(runner: runner, mode: BuildMode.debug),
        );

        expect(runner.calls.single.arguments, isNot(contains('--release')));
        expect(result.succeeded, isTrue,
            reason: 'failed with: ${result.failureMessage}');
        expect(File(planted).existsSync(), isTrue);
        expect(p.basename(result.artifacts.single), 'hello_rust.exe');
      });

      test('a release build does not pick up a debug binary', () async {
        writeExecutable(pathDir, 'cargo');
        writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
        plantExe('hello_rust.exe', profile: 'debug');
        final runner = RecordingProcessRunner();

        final result = await rust.build(request(runner: runner));

        expect(result.succeeded, isFalse);
        expect(result.failureMessage, contains('no .exe'));
      });
    });

    test('a stale .exe from an earlier build is not reported', () async {
      writeExecutable(pathDir, 'cargo');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      // The target directory outlives a build: a renamed or removed [[bin]]
      // leaves an .exe behind that this build did not produce.
      final stale = plantExe('old_name.exe');
      File(stale).setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      final runner = RecordingProcessRunner();

      final result = await rust.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no .exe'));
    });
  });
}
