import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/toolchains/go.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support.dart';

void main() {
  const go = GoToolchain();

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
    projectRoot = projectDir({'go.mod': 'module hello_go\n\ngo 1.21\n'});
  });

  ToolResolver resolver() =>
      ToolResolver(environment: {'HOME': home, 'PATH': pathDir});

  Project project() => Project(
        root: projectRoot,
        type: ProjectType.go,
        name: 'hello_go',
        evidence: const [
          DetectionEvidence(type: ProjectType.go, file: 'go.mod', reason: 'go module'),
        ],
      );

  BuildRequest request({
    required ProcessRunner runner,
    ToolResolver? tools,
    BuildTarget target = BuildTarget.windowsX64,
    BuildMode mode = BuildMode.release,
    List<String> extraArguments = const [],
  }) =>
      BuildRequest(
        project: project(),
        outputDirectory: output,
        cacheDirectory: cache,
        runner: runner,
        tools: tools ?? resolver(),
        output: silentOutput(),
        target: target,
        mode: mode,
        extraArguments: extraArguments,
      );

  test('id and description', () {
    expect(go.id, 'go');
    expect(go.description, isNotEmpty);
  });

  group('canHandle', () {
    test('claims Go projects', () {
      expect(go.canHandle(fakeProject(ProjectType.go)), isTrue);
    });

    test('ignores everything else', () {
      for (final type in ProjectType.values.where((t) => t != ProjectType.go)) {
        expect(go.canHandle(fakeProject(type)), isFalse);
      }
    });
  });

  test('requirements list go, non-optional, with a reason', () {
    final requirements = go.requirements();
    expect(requirements, hasLength(1));
    expect(requirements.single.tool, 'go');
    expect(requirements.single.optional, isFalse);
    expect(requirements.single.reason, contains('windows'));
  });

  group('build', () {
    test('resolves go through ToolResolver, never a bare name', () async {
      final goPath = writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner();

      await go.build(request(runner: runner));

      expect(runner.calls.single.executable, goPath);
      expect(p.isAbsolute(runner.calls.single.executable), isTrue);
    });

    test('release mode: -ldflags, GOOS/GOARCH overlay, GOCACHE under the cache dir', () async {
      writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner();

      final result = await go.build(request(runner: runner));

      final call = runner.calls.single;
      expect(call.arguments, [
        'build',
        '-ldflags', '-s -w',
        '-o', p.join(output, 'hello_go.exe'),
        '.',
      ]);
      expect(call.environment, {
        'GOOS': 'windows',
        'GOARCH': 'amd64',
        'CGO_ENABLED': '0',
        'GOCACHE': p.join(cache, 'go-build'),
      });
      expect(call.workingDirectory, projectRoot);
      expect(result.succeeded, isTrue);
      expect(result.artifacts, [p.join(output, 'hello_go.exe')]);
    });

    test('debug mode omits -ldflags', () async {
      writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner();

      await go.build(request(runner: runner, mode: BuildMode.debug));

      expect(runner.calls.single.arguments, isNot(contains('-ldflags')));
    });

    test('windows-arm64 sets GOARCH=arm64', () async {
      writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner();

      await go.build(request(runner: runner, target: BuildTarget.windowsArm64));

      expect(runner.calls.single.environment['GOARCH'], 'arm64');
    });

    test('extra arguments land before the final "." and never replace it', () async {
      writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner();

      await go.build(request(runner: runner, extraArguments: ['-tags', 'prod']));

      final args = runner.calls.single.arguments;
      expect(args.sublist(args.length - 3), ['-tags', 'prod', '.']);
    });

    test('a non-zero exit becomes BuildResult.failure, not a throw', () async {
      writeExecutable(pathDir, 'go');
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(stderr: 'undefined: fmt.Printl'),
      );

      final result = await go.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('go build failed'));
      expect(result.details, contains('undefined'));
      expect(result.artifacts, isEmpty);
    });

    test('a missing go propagates ToolNotFound rather than failing quietly', () {
      final runner = RecordingProcessRunner();
      expect(
        () => go.build(request(runner: runner)),
        throwsA(isA<ToolNotFound>()),
      );
    });
  });
}
