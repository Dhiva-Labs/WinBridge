import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import 'support/fake_process_runner.dart';

void main() {
  late String home;
  late String toolDir;
  late FakeProcessRunner runner;
  late ToolResolver tools;
  late String sshPath;
  late String rsyncPath;

  setUp(() {
    home = tempDir('home');
    toolDir = tempDir('bin');
    sshPath = writeExecutable(toolDir, 'ssh');
    rsyncPath = writeExecutable(toolDir, 'rsync');
    runner = FakeProcessRunner();
    tools = ToolResolver(environment: {'HOME': home, 'PATH': toolDir});
  });

  const config = VmConfig(
    host: 'winvm.local',
    user: 'builder',
    remoteWorkspace: 'C:/winbridge',
    port: 2222,
    identityFile: '/home/dev/.ssh/id_winbridge',
  );

  OpenSshTransport transportWith({bool acceptNewHostKey = false}) =>
      OpenSshTransport(
        config: config,
        runner: runner,
        tools: tools,
        acceptNewHostKey: acceptNewHostKey,
      );

  group('run', () {
    test('builds exact ssh argv, strict host key checking by default', () async {
      await transportWith().run(['echo', 'hi']);

      expect(runner.calls, hasLength(1));
      final call = runner.calls.single;
      expect(call.executable, sshPath);
      expect(call.arguments, [
        '-p', '2222',
        '-i', '/home/dev/.ssh/id_winbridge',
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=10',
        'builder@winvm.local',
        'echo', 'hi',
      ]);
    });

    test('acceptNewHostKey relaxes to accept-new, never no', () async {
      await transportWith(acceptNewHostKey: true).run(['echo', 'hi']);
      final args = runner.calls.single.arguments;
      expect(args, contains('StrictHostKeyChecking=accept-new'));
      expect(args.join(' '), isNot(contains('StrictHostKeyChecking=no')));
    });

    test('omits -i and IdentitiesOnly when identityFile is unset', () async {
      final noIdentity = OpenSshTransport(
        config: const VmConfig(
          host: 'winvm.local',
          user: 'builder',
          remoteWorkspace: 'C:/winbridge',
        ),
        runner: runner,
        tools: tools,
      );
      await noIdentity.run(['echo', 'hi']);
      final args = runner.calls.single.arguments;
      expect(args, isNot(contains('-i')));
      expect(args.join(' '), isNot(contains('IdentitiesOnly')));
    });

    test('returns the RunResult from ssh verbatim', () async {
      runner.responses.add(failResult(stderr: 'connection refused'));
      final result = await transportWith().run(['echo', 'hi']);
      expect(result.ok, isFalse);
      expect(result.diagnostics, 'connection refused');
    });
  });

  group('sendTree', () {
    test('rsync argv: recursive, no symlinks, excludes, trailing slashes', () async {
      await transportWith().sendTree(
        '/local/project',
        'C:/winbridge/project',
        excludes: const ['build/', '.dart_tool/'],
      );

      expect(runner.calls, hasLength(1));
      final call = runner.calls.single;
      expect(call.executable, rsyncPath);
      expect(call.arguments, [
        '-rt',
        '--no-links',
        '--safe-links',
        '--exclude', 'build/',
        '--exclude', '.dart_tool/',
        '-e', '$sshPath -p 2222 -i /home/dev/.ssh/id_winbridge '
            '-o IdentitiesOnly=yes -o BatchMode=yes '
            '-o StrictHostKeyChecking=yes -o ConnectTimeout=10',
        '/local/project/',
        'builder@winvm.local:C:/winbridge/project/',
      ]);
    });
  });

  group('fetchTree', () {
    test('rsync argv pulls remote to local with the same safety flags', () async {
      final localDir = tempDir('fetch');
      await transportWith().fetchTree('C:/winbridge/project/build/Release', localDir);

      final call = runner.calls.single;
      expect(call.executable, rsyncPath);
      expect(call.arguments, [
        '-rt',
        '--no-links',
        '--safe-links',
        '-e', '$sshPath -p 2222 -i /home/dev/.ssh/id_winbridge '
            '-o IdentitiesOnly=yes -o BatchMode=yes '
            '-o StrictHostKeyChecking=yes -o ConnectTimeout=10',
        'builder@winvm.local:C:/winbridge/project/build/Release/',
        '$localDir/',
      ]);
    });

    test('does not scan the destination when rsync itself failed', () async {
      final localDir = tempDir('fetch');
      runner.responses.add(failResult(stderr: 'rsync error'));
      final result = await transportWith().fetchTree('C:/remote', localDir);
      expect(result.ok, isFalse);
    });

    test('validates every fetched file sits inside the destination', () async {
      final localDir = tempDir('fetch');
      writeFile(p.join(localDir, 'app.exe'), 'MZ');
      writeFile(p.join(localDir, 'data', 'flutter_assets', 'file'), 'x');

      final result = await transportWith().fetchTree('C:/remote', localDir);
      expect(result.ok, isTrue);
    });

    test('rejects a symlink left behind in the fetched tree', () async {
      final localDir = tempDir('fetch');
      final outside = writeFile(p.join(tempDir('outside'), 'payload'), 'x');
      Link(p.join(localDir, 'app.exe')).createSync(outside);

      expect(
        () => transportWith().fetchTree('C:/remote', localDir),
        throwsA(isA<ArtifactFailure>()),
      );
    });
  });
}
