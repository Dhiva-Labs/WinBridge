import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';

const _config = VmConfig(
  host: 'winvm.local',
  user: 'builder',
  remoteWorkspace: 'C:/winbridge',
);

void main() {
  final commands = RemoteCommands(_config);

  test('remoteProjectDir is a fixed name under the workspace, never the '
      'project\'s own name', () {
    expect(commands.remoteProjectDir, 'C:/winbridge/project');
  });

  test('a trailing slash on the workspace is not doubled', () {
    final trailing = RemoteCommands(const VmConfig(
      host: 'winvm.local',
      user: 'builder',
      remoteWorkspace: 'C:/winbridge/',
    ));
    expect(trailing.remoteProjectDir, 'C:/winbridge/project');
  });

  test('remoteReleaseDir sits under the fixed project dir', () {
    expect(
      commands.remoteReleaseDir,
      'C:/winbridge/project/build/windows/x64/runner/Release',
    );
  });

  test('echoProbe is a fixed literal, independent of config', () {
    expect(commands.echoProbe(), ['echo', 'winbridge-vm-ok']);
  });

  test('flutterVersion uses bare flutter when flutterPath is unset', () {
    expect(commands.flutterVersion(), ['flutter', '--version']);
  });

  test('flutterVersion quotes flutterPath when set', () {
    final withPath = RemoteCommands(const VmConfig(
      host: 'winvm.local',
      user: 'builder',
      remoteWorkspace: 'C:/winbridge',
      flutterPath: 'C:/tools/flutter/bin/flutter.bat',
    ));
    expect(withPath.flutterVersion(), ['"C:/tools/flutter/bin/flutter.bat"', '--version']);
  });

  test('pubGet cds into the quoted project dir first', () {
    expect(commands.pubGet(), [
      'cd', '/d', '"C:/winbridge/project"',
      '&&',
      'flutter', 'pub', 'get',
    ]);
  });

  test('ensureWindowsPlatform only creates the folder when absent', () {
    expect(commands.ensureWindowsPlatform(), [
      'cd', '/d', '"C:/winbridge/project"',
      '&&',
      'if', 'not', 'exist', 'windows',
      'flutter', 'create', '--platforms=windows', '.',
    ]);
  });

  test('buildWindowsRelease', () {
    expect(commands.buildWindowsRelease(), [
      'cd', '/d', '"C:/winbridge/project"',
      '&&',
      'flutter', 'build', 'windows', '--release',
    ]);
  });

  test('whereRsync is a fixed literal', () {
    expect(commands.whereRsync(), ['where', 'rsync']);
  });

  test('every token across every command comes from config or a literal — '
      'nothing here can smuggle a project name onto the remote command line',
      () {
    final all = [
      ...commands.pubGet(),
      ...commands.ensureWindowsPlatform(),
      ...commands.buildWindowsRelease(),
    ].join(' ');
    expect(all, isNot(contains('pubspec')));
    expect(all, isNot(contains('..')));
  });

  // The far end of this one ssh invocation really is a shell, so the whole
  // safety argument rests on every token being a literal or a charset-checked
  // config field. Assert that directly rather than trusting the reading.
  test('no emitted token carries a cmd.exe metacharacter', () {
    const deliberateOperators = {'&&'};
    final metacharacter = RegExp(r'[&|<>^%\r\n]');

    for (final config in [
      _config,
      const VmConfig(
        host: 'winvm.local',
        user: 'builder',
        remoteWorkspace: 'C:/winbridge/',
        flutterPath: 'C:/tools/flutter/bin/flutter.bat',
      ),
    ]) {
      final remote = RemoteCommands(config);
      for (final command in [
        remote.echoProbe(),
        remote.flutterVersion(),
        remote.pubGet(),
        remote.ensureWindowsPlatform(),
        remote.buildWindowsRelease(),
        remote.whereRsync(),
      ]) {
        for (final token in command) {
          if (deliberateOperators.contains(token)) continue;
          expect(
            metacharacter.hasMatch(token),
            isFalse,
            reason: 'token "$token" could be reinterpreted by cmd.exe',
          );
          // A quoted token must not be able to close its own quote early.
          if (token.startsWith('"')) {
            expect(token.substring(1, token.length - 1), isNot(contains('"')));
          }
        }
      }
    }
  });
}
