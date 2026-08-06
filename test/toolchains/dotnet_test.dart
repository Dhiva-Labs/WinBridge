import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/toolchains/dotnet.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support.dart';

void main() {
  const dotnet = DotnetToolchain();

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
      'hello_dotnet.csproj': '<Project Sdk="Microsoft.NET.Sdk" />\n',
    });
  });

  ToolResolver resolver() =>
      ToolResolver(environment: {'HOME': home, 'PATH': pathDir});

  Project project() => Project(
        root: projectRoot,
        type: ProjectType.dotnet,
        name: 'hello_dotnet',
        evidence: const [
          DetectionEvidence(
              type: ProjectType.dotnet,
              file: 'hello_dotnet.csproj',
              reason: 'msbuild project'),
        ],
      );

  BuildRequest request({
    required ProcessRunner runner,
    List<String> extraArguments = const [],
  }) =>
      BuildRequest(
        project: project(),
        outputDirectory: output,
        cacheDirectory: cache,
        runner: runner,
        tools: resolver(),
        output: silentOutput(),
        extraArguments: extraArguments,
      );

  test('id and description', () {
    expect(dotnet.id, 'dotnet');
    expect(dotnet.description, contains('win-x64'));
  });

  group('canHandle', () {
    test('claims .NET projects', () {
      expect(dotnet.canHandle(fakeProject(ProjectType.dotnet)), isTrue);
    });

    test('ignores everything else', () {
      for (final type in ProjectType.values.where((t) => t != ProjectType.dotnet)) {
        expect(dotnet.canHandle(fakeProject(type)), isFalse);
      }
    });
  });

  test('requirements list dotnet, non-optional', () {
    final requirements = dotnet.requirements();
    expect(requirements, hasLength(1));
    expect(requirements.single.tool, 'dotnet');
    expect(requirements.single.optional, isFalse);
  });

  group('build', () {
    test('missing dotnet propagates ToolNotFound', () {
      final runner = RecordingProcessRunner();
      expect(() => dotnet.build(request(runner: runner)), throwsA(isA<ToolNotFound>()));
    });

    test('argv: publish -r win-x64 -c Release --self-contained false -o <output>', () async {
      final dotnetPath = writeExecutable(pathDir, 'dotnet');
      writeFile(p.join(output, 'hello_dotnet.exe'));
      final runner = RecordingProcessRunner();

      await dotnet.build(request(runner: runner, extraArguments: ['-v', 'quiet']));

      final call = runner.calls.single;
      expect(call.executable, dotnetPath);
      expect(call.arguments, [
        'publish',
        '-r', 'win-x64',
        '-c', 'Release',
        '--self-contained', 'false',
        '-o', output,
        '-v', 'quiet',
      ]);
      expect(call.workingDirectory, projectRoot);
    });

    test('returns only the apphost .exe, not the managed .dll beside it', () async {
      writeExecutable(pathDir, 'dotnet');
      writeFile(p.join(output, 'hello_dotnet.exe'));
      writeFile(p.join(output, 'hello_dotnet.dll'));
      writeFile(p.join(output, 'hello_dotnet.deps.json'));
      final runner = RecordingProcessRunner();

      final result = await dotnet.build(request(runner: runner));

      expect(result.succeeded, isTrue);
      expect(result.artifacts, [p.join(output, 'hello_dotnet.exe')]);
    });

    test('dotnet exiting non-zero is a failure, not a throw', () async {
      writeExecutable(pathDir, 'dotnet');
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(stderr: 'MSB1234: build error'),
      );

      final result = await dotnet.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('dotnet publish failed'));
      expect(result.details, contains('MSB1234'));
    });

    test('success without an apphost .exe fails with an actionable message', () async {
      writeExecutable(pathDir, 'dotnet');
      writeFile(p.join(output, 'hello_dotnet.dll'));
      final runner = RecordingProcessRunner();

      final result = await dotnet.build(request(runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no apphost .exe'));
      expect(result.details, contains('UseAppHost'));
    });
  });
}
