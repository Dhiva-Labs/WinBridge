import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/cli/runner.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// End-to-end coverage through the real `winbridge desktop` CLI wiring,
/// built by hand here exactly the way the composition root will: a fresh
/// `WinBridgeRunner` with `DesktopCommand` added. The tech lead's slice wires
/// this into `lib/src/cli/runner.dart` itself; this file proves the command
/// behaves once that one line lands, without touching that file.
void main() {
  late String home;
  late String appsDir;
  late String exe;

  String applicationsDir(String home) =>
      p.join(home, '.local', 'share', 'applications');

  /// A [WinBridgeRunner] scoped to a temp `$HOME` and with no `PATH` at all —
  /// so `ToolResolver` can never find a real `update-desktop-database`, and
  /// the best-effort refresh after add/remove is a deterministic no-op
  /// without needing a fake `ProcessRunner`.
  WinBridgeRunner buildRunner(StringBuffer out) {
    return WinBridgeRunner(
      config: WinBridgeConfig(environment: {'HOME': home}),
      out: out,
      err: out,
    );
  }

  setUp(() {
    home = tempDir('home');
    appsDir = applicationsDir(home);
    exe = p.join(tempDir('app'), 'hello.exe');
    File(exe).writeAsBytesSync([0x4d, 0x5a, 0x00, 0x00]);
  });

  group('add', () {
    test('writes an entry and exits 0', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['desktop', 'add', exe]);

      expect(code, 0);
      final path = p.join(appsDir, 'winbridge-hello.desktop');
      expect(File(path).existsSync(), isTrue);
      expect(File(path).readAsStringSync(), contains('X-WinBridge=true'));
      expect(File(path).readAsStringSync(), contains(exe));
      expect(out.toString(), contains('Added'));
    });

    test('--name and --prefix are honoured', () async {
      final code = await buildRunner(StringBuffer()).execute([
        'desktop', 'add', exe,
        '--name', 'My Game',
        '--prefix', 'shared',
      ]);
      expect(code, 0);
      final content =
          File(p.join(appsDir, 'winbridge-hello.desktop')).readAsStringSync();
      expect(content, contains('Name=My Game'));
      expect(content, contains('--prefix "shared"'));
    });

    test('remove works by slug and by display name', () async {
      await buildRunner(StringBuffer())
          .execute(['desktop', 'add', exe, '--name', 'My Game']);
      var code = await buildRunner(StringBuffer())
          .execute(['desktop', 'remove', 'My Game']);
      expect(code, 0);
      expect(File(p.join(appsDir, 'winbridge-hello.desktop')).existsSync(),
          isFalse);

      await buildRunner(StringBuffer())
          .execute(['desktop', 'add', exe, '--name', 'My Game']);
      code = await buildRunner(StringBuffer())
          .execute(['desktop', 'remove', 'hello']);
      expect(code, 0);
      expect(File(p.join(appsDir, 'winbridge-hello.desktop')).existsSync(),
          isFalse);
    });

    test('a name carrying "\\nExec=" is rejected and nothing is written', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute([
        'desktop', 'add', exe,
        '--name', 'evil\nExec=rm -rf ~',
      ]);

      expect(code, 2);
      expect(Directory(appsDir).existsSync(), isFalse,
          reason: 'the injected value must be rejected before any write');
    });

    test('a file without the MZ header is rejected', () async {
      final notAnExe = p.join(tempDir('app2'), 'not.exe');
      File(notAnExe).writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46]);

      final code =
          await buildRunner(StringBuffer()).execute(['desktop', 'add', notAnExe]);
      expect(code, 2);
      expect(Directory(appsDir).existsSync(), isFalse);
    });

    test('a missing positional argument is a usage error', () async {
      final code = await buildRunner(StringBuffer()).execute(['desktop', 'add']);
      expect(code, 2);
    });
  });

  group('list', () {
    test('reports nothing before anything has been added', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['desktop', 'list']);
      expect(code, 0);
      expect(out.toString(), contains('no desktop entries'));
    });

    test('shows an entry added moments before', () async {
      await buildRunner(StringBuffer()).execute(['desktop', 'add', exe]);
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['desktop', 'list']);
      expect(code, 0);
      expect(out.toString(), contains('hello'));
      expect(out.toString(), contains(exe));
    });
  });

  group('remove', () {
    test('deletes an entry added moments before', () async {
      await buildRunner(StringBuffer()).execute(['desktop', 'add', exe]);
      final path = p.join(appsDir, 'winbridge-hello.desktop');
      expect(File(path).existsSync(), isTrue);

      final code =
          await buildRunner(StringBuffer()).execute(['desktop', 'remove', 'hello']);
      expect(code, 0);
      expect(File(path).existsSync(), isFalse);
    });

    test('a name nothing owns is a clear usage error', () async {
      final code = await buildRunner(StringBuffer())
          .execute(['desktop', 'remove', 'nope']);
      expect(code, 2);
    });

    test('never touches a file that lacks the ownership marker', () async {
      final path = writeFile(
        p.join(appsDir, 'winbridge-crafted.desktop'),
        '[Desktop Entry]\nName=crafted\n',
      );
      final code = await buildRunner(StringBuffer())
          .execute(['desktop', 'remove', 'crafted']);
      expect(code, 2);
      expect(File(path).existsSync(), isTrue);
    });
  });
}
