import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support.dart';

void main() {
  const c = CToolchain();

  late String home;
  late String pathDir;
  late String output;
  late String cache;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    output = tempDir('out');
    cache = tempDir('cache');
  });

  ToolResolver resolver() =>
      ToolResolver(environment: {'HOME': home, 'PATH': pathDir});

  Project project(String root) => Project(
        root: root,
        type: ProjectType.c,
        name: 'hello_c',
        evidence: const [
          DetectionEvidence(type: ProjectType.c, file: 'main.c', reason: 'C/C++ sources'),
        ],
      );

  BuildRequest request({
    required String root,
    required ProcessRunner runner,
    BuildMode mode = BuildMode.release,
    List<String> extraArguments = const [],
  }) =>
      BuildRequest(
        project: project(root),
        outputDirectory: output,
        cacheDirectory: cache,
        runner: runner,
        tools: resolver(),
        output: silentOutput(),
        mode: mode,
        extraArguments: extraArguments,
      );

  test('id and description', () {
    expect(c.id, 'c');
    expect(c.description, isNotEmpty);
  });

  group('canHandle', () {
    test('claims C projects', () {
      expect(c.canHandle(fakeProject(ProjectType.c)), isTrue);
    });

    test('ignores everything else', () {
      for (final type in ProjectType.values.where((t) => t != ProjectType.c)) {
        expect(c.canHandle(fakeProject(type)), isFalse);
      }
    });
  });

  test('requirements prefer zig, with mingw as alternatives', () {
    final requirements = c.requirements();
    expect(requirements, hasLength(1));
    expect(requirements.single.tool, 'zig');
    expect(requirements.single.optional, isFalse);
    expect(
      requirements.single.alternatives,
      containsAll(['x86_64-w64-mingw32-gcc', 'x86_64-w64-mingw32-g++']),
    );
  });

  group('build: source discovery', () {
    test('fails clearly when only CMakeLists.txt exists', () async {
      final root = projectDir({'CMakeLists.txt': 'cmake_minimum_required(VERSION 3.10)\n'});
      final runner = RecordingProcessRunner();

      final result = await c.build(request(root: root, runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no direct C/C++ sources'));
      expect(result.details, contains('CMake'));
      expect(runner.calls, isEmpty);
    });

    test('fails clearly when only a Makefile exists', () async {
      final root = projectDir({'Makefile': 'all:\n\techo hi\n'});
      final runner = RecordingProcessRunner();

      final result = await c.build(request(root: root, runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no direct C/C++ sources'));
    });

    test('collects top-level and src/ sources, sorted, headers excluded', () async {
      final root = projectDir({
        'main.c': '',
        'helper.h': '',
        'src/util.c': '',
        'src/README.md': '',
      });
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      final args = runner.calls.single.arguments;
      final sources = args.where((a) => a.endsWith('.c')).toList();
      expect(sources, [
        p.join(root, 'main.c'),
        p.join(root, 'src', 'util.c'),
      ]);
    });
  });

  group('build: compiler selection', () {
    test('prefers zig over mingw when both resolve', () async {
      final root = projectDir({'main.c': ''});
      final zigPath = writeExecutable(pathDir, 'zig');
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      expect(runner.calls.single.executable, zigPath);
    });

    test('zig invocation: cc subcommand and target flag, sources after -o', () async {
      final root = projectDir({'main.c': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      final call = runner.calls.single;
      final exe = p.join(output, 'hello_c.exe');
      expect(call.arguments, [
        'cc',
        '-target', 'x86_64-windows-gnu',
        '-O2',
        '-o', exe,
        p.join(root, 'main.c'),
      ]);
      expect(call.environment, {
        'ZIG_GLOBAL_CACHE_DIR': p.join(cache, 'zig-cache'),
        'ZIG_LOCAL_CACHE_DIR': p.join(cache, 'zig-cache', 'local'),
      });
    });

    test('debug mode omits -O2', () async {
      final root = projectDir({'main.c': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner, mode: BuildMode.debug));

      expect(runner.calls.single.arguments, isNot(contains('-O2')));
    });

    test('C++ sources use zig c++', () async {
      final root = projectDir({'main.cpp': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      expect(runner.calls.single.arguments.first, 'c++');
    });

    test('falls back to mingw gcc for C when zig is absent', () async {
      final root = projectDir({'main.c': ''});
      final gccPath = writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      final call = runner.calls.single;
      expect(call.executable, gccPath);
      // No zig subcommand or -target: the mingw binary is already target-specific.
      expect(call.arguments, isNot(contains('cc')));
      expect(call.arguments, isNot(contains('-target')));
      expect(call.environment, isEmpty);
    });

    test('falls back to mingw g++ for C++ when zig is absent', () async {
      final root = projectDir({'main.cpp': ''});
      writeExecutable(pathDir, 'x86_64-w64-mingw32-gcc');
      final gxxPath = writeExecutable(pathDir, 'x86_64-w64-mingw32-g++');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner));

      expect(runner.calls.single.executable, gxxPath);
    });

    test('neither zig nor a mingw compiler propagates ToolNotFound', () {
      final root = projectDir({'main.c': ''});
      final runner = RecordingProcessRunner();

      expect(
        () => c.build(request(root: root, runner: runner)),
        throwsA(isA<ToolNotFound>()),
      );
    });

    test('extra arguments land between -o and the sources', () async {
      final root = projectDir({'main.c': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      await c.build(request(root: root, runner: runner, extraArguments: ['-DFOO=1']));

      final args = runner.calls.single.arguments;
      final oIndex = args.indexOf('-o');
      final extraIndex = args.indexOf('-DFOO=1');
      final sourceIndex = args.indexOf(p.join(root, 'main.c'));
      expect(oIndex, lessThan(extraIndex));
      expect(extraIndex, lessThan(sourceIndex));
    });
  });

  group('build: results', () {
    test('a compile failure becomes BuildResult.failure, not a throw', () async {
      final root = projectDir({'main.c': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(stderr: "error: use of undeclared identifier 'x'"),
      );

      final result = await c.build(request(root: root, runner: runner));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('failed'));
      expect(result.details, contains('undeclared identifier'));
    });

    test('success returns the .exe as the sole artifact', () async {
      final root = projectDir({'main.c': ''});
      writeExecutable(pathDir, 'zig');
      final runner = RecordingProcessRunner();

      final result = await c.build(request(root: root, runner: runner));

      expect(result.succeeded, isTrue);
      expect(result.artifacts, [p.join(output, 'hello_c.exe')]);
    });
  });
}
