import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support/fake_process_runner.dart';
import 'support/fake_vm_transport.dart';

void main() {
  late String outputDir;
  late String cacheDir;
  late String configPath;

  setUp(() {
    outputDir = tempDir('out');
    cacheDir = tempDir('cache');
    configPath = writeFile(
      p.join(tempDir('cfg'), 'vm.json'),
      jsonEncode({
        'host': 'winvm.local',
        'user': 'builder',
        'remoteWorkspace': 'C:/winbridge',
      }),
    );
  });

  BuildRequest requestFor(Project project, {String? root}) => BuildRequest(
        project: root == null ? project : fakeProject(project.type, root: root),
        outputDirectory: outputDir,
        cacheDirectory: cacheDir,
        runner: FakeProcessRunner(),
        tools: ToolResolver(environment: const {'PATH': ''}),
        output: Output(),
      );

  FlutterVmToolchain toolchainWith(
    FakeVmTransport transport, {
    String? configPathOverride,
  }) =>
      FlutterVmToolchain(
        environment: {
          'WINBRIDGE_VM_CONFIG': configPathOverride ?? configPath,
        },
        transportFactory: (config, request) => transport,
      );

  test('id and description', () {
    final toolchain = FlutterVmToolchain();
    expect(toolchain.id, 'vm');
    expect(toolchain.description, isNotEmpty);
  });

  test('canHandle only flutter projects', () {
    final toolchain = FlutterVmToolchain();
    expect(toolchain.canHandle(fakeProject(ProjectType.flutter)), isTrue);
    expect(toolchain.canHandle(fakeProject(ProjectType.go)), isFalse);
    expect(toolchain.canHandle(fakeProject(ProjectType.rust)), isFalse);
  });

  test('requirements never do I/O and list ssh, rsync and the vm as optional', () {
    final requirements = FlutterVmToolchain().requirements();
    final tools = {for (final r in requirements) r.tool: r};
    expect(tools['ssh']?.optional, isFalse);
    expect(tools['rsync']?.optional, isFalse);
    expect(tools['configured vm']?.optional, isTrue);
  });

  test('a missing VM config fails the build, does not throw', () async {
    final toolchain = toolchainWith(
      FakeVmTransport(),
      configPathOverride: p.join(tempDir(), 'nowhere.json'),
    );

    final result =
        await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

    expect(result.succeeded, isFalse);
    expect(result.failureMessage, contains('no VM config'));
  });

  group('build sequence', () {
    test('runs send, pub get, ensure-windows, build, fetch in order', () async {
      writeFile(p.join(outputDir, 'hello_flutter.exe'), 'MZ');
      writeFile(p.join(outputDir, 'flutter_windows.dll'), 'dll');

      final transport = FakeVmTransport();
      final root = tempDir('project');
      final toolchain = toolchainWith(transport);

      final result = await toolchain.build(
        requestFor(fakeProject(ProjectType.flutter, root: root), root: root),
      );

      expect(result.succeeded, isTrue);
      expect(transport.calls.map((c) => c.kind).toList(),
          ['send', 'run', 'run', 'run', 'fetch']);

      expect(transport.calls[0].localDir, root);
      expect(transport.calls[0].remoteDir, 'C:/winbridge/project');

      expect(transport.calls[1].remoteArgs, contains('get'));
      expect(transport.calls[2].remoteArgs, contains('create'));
      expect(transport.calls[3].remoteArgs, containsAllInOrder(['build', 'windows', '--release']));

      expect(transport.calls[4].remoteDir,
          'C:/winbridge/project/build/windows/x64/runner/Release');
      expect(transport.calls[4].localDir, outputDir);

      expect(result.artifacts.first, endsWith('hello_flutter.exe'));
      expect(result.artifacts.any((a) => a.endsWith('flutter_windows.dll')), isTrue);
      expect(result.summary, contains('vm'));
      expect(result.duration, isNotNull);
    });

    test('a failed sync stops before any remote command runs', () async {
      final transport = FakeVmTransport()..results.add(failResult(stderr: 'no route'));
      final toolchain = toolchainWith(transport);

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('sync'));
      expect(result.details, contains('no route'));
      expect(transport.calls.map((c) => c.kind).toList(), ['send']);
    });

    test('a failed pub get stops before create or build run', () async {
      final transport = FakeVmTransport()
        ..results.addAll([okResult(), failResult(stderr: 'no internet')]);
      final toolchain = toolchainWith(transport);

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('pub get'));
      expect(transport.calls.map((c) => c.kind).toList(), ['send', 'run']);
    });

    test('a failed platform-create stops before the release build runs', () async {
      final transport = FakeVmTransport()
        ..results.addAll([okResult(), okResult(), failResult(stderr: 'create failed')]);
      final toolchain = toolchainWith(transport);

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('create'));
      expect(transport.calls.map((c) => c.kind).toList(), ['send', 'run', 'run']);
    });

    test('a failed release build stops before fetch', () async {
      final transport = FakeVmTransport()
        ..results.addAll([okResult(), okResult(), okResult(), failResult(stderr: 'compile error')]);
      final toolchain = toolchainWith(transport);

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('build windows'));
      expect(result.details, contains('compile error'));
      expect(transport.calls.map((c) => c.kind).toList(), ['send', 'run', 'run', 'run']);
    });

    test('a failed fetch fails the build after everything else succeeded', () async {
      final transport = FakeVmTransport()
        ..results.addAll(
            [okResult(), okResult(), okResult(), okResult(), failResult(stderr: 'broken pipe')]);
      final toolchain = toolchainWith(transport);

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('fetching'));
      expect(transport.calls.map((c) => c.kind).toList(),
          ['send', 'run', 'run', 'run', 'fetch']);
    });

    test('a fetch that leaves no files behind fails the build', () async {
      final toolchain = toolchainWith(FakeVmTransport());

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('no files'));
    });

    test('artifact paths are validated inside the output directory', () async {
      writeFile(p.join(outputDir, 'hello_flutter.exe'), 'MZ');
      final toolchain = toolchainWith(FakeVmTransport());

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isTrue);
      for (final artifact in result.artifacts) {
        expect(p.isWithin(outputDir, artifact), isTrue);
      }
    });

    test('a symlink left in the output directory fails the build', () async {
      final outside = writeFile(p.join(tempDir('outside'), 'payload'), 'x');
      Link(p.join(outputDir, 'app.exe')).createSync(outside);
      final toolchain = toolchainWith(FakeVmTransport());

      final result =
          await toolchain.build(requestFor(fakeProject(ProjectType.flutter)));

      expect(result.succeeded, isFalse);
    });
  });
}
