import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/cli/runner.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// End-to-end coverage of `winbridge vm app`, through the real CLI wiring.
/// Unlike `recipe`, `vm` is already registered in `lib/src/cli/runner.dart`
/// (`addCommand(VmCommand())`), and `VmAppCommand` is added as one of its
/// subcommands inside `lib/src/vm/vm_command.dart`, which this module owns —
/// so no external wiring is needed for these tests, or for `vm app` itself,
/// to work.
void main() {
  late String home;
  late String pathDir;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
  });

  void writeVmConfig({int port = 2222}) {
    final dir = p.join(home, '.config', 'winbridge');
    writeFile(
      p.join(dir, 'vm.json'),
      '{"host": "127.0.0.1", "port": $port, "user": "winbridge", '
      '"remoteWorkspace": "C:/winbridge"}',
    );
  }

  WinBridgeRunner buildRunner(StringBuffer out, {Map<String, String> extraEnv = const {}}) {
    final config = WinBridgeConfig(environment: {
      'HOME': home,
      'PATH': pathDir,
      ...extraEnv,
    });
    return WinBridgeRunner(config: config, out: out, err: out);
  }

  group('argument validation', () {
    test('rejects the wrong number of arguments', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['vm', 'app']);
      expect(code, 2);
    });

    test('rejects a path with spaces, explaining why', () async {
      writeVmConfig();
      final out = StringBuffer();
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/Program Files/App/app.exe']);
      expect(code, 2);
      expect(out.toString(), contains('invalid remote executable path'));
      expect(out.toString(), contains('remoteWorkspace'));
    });

    test('rejects a path carrying ".."', () async {
      writeVmConfig();
      final out = StringBuffer();
      final code =
          await buildRunner(out).execute(['vm', 'app', 'C:/apps/../app.exe']);
      expect(code, 2);
    });

    test('validates the path before ever touching config or tools', () async {
      // No vm.json written at all — if path validation happened after config
      // loading, this would fail with a VmConfigError instead.
      final out = StringBuffer();
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/Program Files/App/app.exe']);
      expect(code, 2);
      expect(out.toString(), isNot(contains('vm-setup.md')));
    });
  });

  group('the WINBRIDGE_RDP_ASK gap', () {
    test('refuses clearly instead of hanging or prompting insecurely',
        () async {
      writeVmConfig();
      final out = StringBuffer();
      final code = await buildRunner(out, extraEnv: {rdpAskPasswordVariable: '1'})
          .execute(['vm', 'app', 'C:/apps/App/app.exe']);
      expect(code, 2);
      expect(out.toString(), contains('not supported yet'));
      expect(out.toString(), contains('docs/remoteapp.md'));
    });
  });

  group('no FreeRDP client available', () {
    test('names the package to install and points at the docs', () async {
      writeVmConfig();
      final out = StringBuffer();
      // pathDir is empty, so none of the client candidates resolve.
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/apps/App/app.exe']);
      expect(code, 1);
      expect(out.toString(), contains('freerdp3-x11'));
      expect(out.toString(), contains('docs/remoteapp.md'));
      expect(out.toString(), contains('xfreerdp'));
    });
  });

  group('missing VM config', () {
    test('reports it the same way vm status/doctor already do', () async {
      // No vm.json — but a resolvable client, so the missing config is what
      // actually stops this, not the tool search.
      writeExecutable(pathDir, 'xfreerdp');
      final out = StringBuffer();
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/apps/App/app.exe']);
      expect(code, 1);
      expect(out.toString(), contains('vm-setup.md'));
    });
  });

  group('the happy path', () {
    test('resolves a client, loads the vm config, and spawns with the '
        'expected argv — reaching the same launch step run/prefix reach for '
        'Wine', () async {
      writeVmConfig(port: 3390);
      // A stand-in "xfreerdp": Dart cannot chmod a file it writes itself, so
      // this reuses the same trick `test/support/fixtures.dart` documents —
      // a symlink to a real, already-executable binary that exits 0
      // instantly. It really is spawned via ProcessRunner; nothing about
      // this test is faked below the CLI layer.
      writeExecutable(pathDir, 'xfreerdp');

      final out = StringBuffer();
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/apps/App/app.exe', '--sound']);

      expect(code, 0);
      expect(out.toString(), contains('client'));
      expect(out.toString(), contains(p.join(pathDir, 'xfreerdp')));
      expect(out.toString(), contains('winbridge@127.0.0.1:3390'));
      expect(out.toString(), contains('C:/apps/App/app.exe'));
    });

    test('the app\'s own exit code becomes this command\'s exit code',
        () async {
      writeVmConfig();
      // /bin/false always exits 1; symlinking straight to it (rather than
      // through writeExecutable, which is pinned to /bin/true) proves the
      // exit code is the child's, not a hardcoded 0.
      final falseBinary = ['/bin/false', '/usr/bin/false']
          .firstWhere((c) => File(c).existsSync());
      Link(p.join(pathDir, 'xfreerdp')).createSync(falseBinary);

      final out = StringBuffer();
      final code = await buildRunner(out)
          .execute(['vm', 'app', 'C:/apps/App/app.exe']);
      expect(code, 1);
    });
  });
}
