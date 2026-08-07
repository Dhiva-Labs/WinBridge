import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/desktop/desktop_entry.dart';
import 'package:winbridge/src/desktop/desktop_store.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late DesktopEntryStore store;

  String expectedDir(String home) =>
      p.join(home, '.local', 'share', 'applications');

  setUp(() {
    home = tempDir('home');
    store = DesktopEntryStore(WinBridgeConfig(environment: {'HOME': home}));
  });

  group('location', () {
    test('is ~/.local/share/applications, not a winbridge-private directory', () {
      expect(store.directory, expectedDir(home));
      expect(store.directory, isNot(contains('winbridge')));
    });

    test('honours XDG_DATA_HOME, all tests confined to a temp dir', () {
      final data = tempDir('xdg');
      final scoped = DesktopEntryStore(
        WinBridgeConfig(environment: {'HOME': home, 'XDG_DATA_HOME': data}),
      );
      expect(scoped.directory, p.join(data, 'applications'));
      expect(scoped.directory, isNot(contains(home)));
    });

    test('fails cleanly with no home to work from', () {
      final scoped = DesktopEntryStore(WinBridgeConfig(environment: const {}));
      expect(() => scoped.directory, throwsA(isA<BuildFailure>()));
    });
  });

  group('write', () {
    test('creates the applications directory and the file', () {
      final entry = DesktopEntry(
        slug: 'hello_c',
        name: 'hello_c',
        prefix: 'hello_c',
        executablePath: '/apps/hello_c.exe',
      );
      final path = store.write(entry);
      expect(path, p.join(expectedDir(home), 'winbridge-hello_c.desktop'));
      expect(File(path).readAsStringSync(), contains('X-WinBridge=true'));
    });

    test('re-adding the same app updates its own entry', () {
      final first = DesktopEntry(
        slug: 'app',
        name: 'app', prefix: 'app', executablePath: '/apps/app.exe',
      );
      final path = store.write(first);
      final second = DesktopEntry(
        slug: 'app',
        name: 'app', prefix: 'shared', executablePath: '/apps/app-v2.exe',
      );
      store.write(second);
      expect(File(path).readAsStringSync(), contains('/apps/app-v2.exe'));
      expect(File(path).readAsStringSync(), contains('--prefix "shared"'));
    });

    test('refuses to overwrite a file it does not own', () {
      final path = p.join(expectedDir(home), 'winbridge-app.desktop');
      writeFile(path, '[Desktop Entry]\nName=someone else\n');

      final entry = DesktopEntry(
        slug: 'app',
        name: 'app', prefix: 'app', executablePath: '/apps/app.exe',
      );
      expect(() => store.write(entry), throwsA(isA<UsageFailure>()));
      expect(File(path).readAsStringSync(), isNot(contains('WinBridge')));
    });
  });

  group('list parses its own output', () {
    test('is empty before anything has been added', () {
      expect(store.list(), isEmpty);
    });

    test('reports name and target for entries it wrote, sorted by file name', () {
      store.write(DesktopEntry(
        slug: 'zebra',
        name: 'zebra', prefix: 'zebra', executablePath: '/apps/zebra.exe',
      ));
      store.write(DesktopEntry(
        slug: 'apple',
        name: 'apple', prefix: 'apple', executablePath: '/apps/apple.exe',
      ));

      final entries = store.list();
      expect(entries.map((e) => e.name), ['apple', 'zebra']);
      expect(entries.map((e) => e.target), [
        '/apps/apple.exe',
        '/apps/zebra.exe',
      ]);
    });

    test('recovers a target path containing spaces', () {
      store.write(DesktopEntry(
        slug: 'game',
        name: 'game',
        prefix: 'game',
        executablePath: '/opt/My Games/game.exe',
      ));
      expect(store.list().single.target, '/opt/My Games/game.exe');
    });

    test('ignores a winbridge-named file with no ownership marker', () {
      writeFile(
        p.join(expectedDir(home), 'winbridge-foreign.desktop'),
        '[Desktop Entry]\nName=foreign\nExec=/bin/true\n',
      );
      expect(store.list(), isEmpty);
    });

    test('ignores a .desktop file that is not winbridge-named', () {
      writeFile(
        p.join(expectedDir(home), 'other-app.desktop'),
        '[Desktop Entry]\nName=other\nX-WinBridge=true\n',
      );
      expect(store.list(), isEmpty);
    });
  });

  group('remove', () {
    test('deletes an owned entry by its name', () {
      final entry = DesktopEntry(
        slug: 'app',
        name: 'app', prefix: 'app', executablePath: '/apps/app.exe',
      );
      final path = store.write(entry);
      expect(File(path).existsSync(), isTrue);

      store.remove('app');
      expect(File(path).existsSync(), isFalse);
    });

    test('never glob-deletes: removing one entry leaves the others', () {
      final keep = store.write(DesktopEntry(
        slug: 'keep',
        name: 'keep', prefix: 'keep', executablePath: '/apps/keep.exe',
      ));
      store.write(DesktopEntry(
        slug: 'gone',
        name: 'gone', prefix: 'gone', executablePath: '/apps/gone.exe',
      ));

      store.remove('gone');
      expect(File(keep).existsSync(), isTrue);
    });

    test('rejects a traversal attempt before touching the filesystem', () {
      for (final bad in ['../../etc/passwd', '..', '.', 'a/b', '']) {
        expect(
          () => store.remove(bad),
          throwsA(isA<UsageFailure>()),
          reason: 'accepted "$bad"',
        );
      }
      // Nothing outside the applications directory was ever created.
      expect(Directory(p.join(home, 'etc')).existsSync(), isFalse);
    });

    test('a missing entry is a clear usage error, not a crash', () {
      expect(() => store.remove('nope'), throwsA(isA<UsageFailure>()));
    });
  });

  group('removeOwnedFile — the low-level ownership guard', () {
    test('refuses a file whose name does not start with winbridge-', () {
      final path = writeFile(
        p.join(expectedDir(home), 'evil.desktop'),
        '[Desktop Entry]\nX-WinBridge=true\n',
      );
      expect(
        () => store.removeOwnedFile(path),
        throwsA(isA<UsageFailure>()),
      );
      expect(File(path).existsSync(), isTrue);
    });

    test('refuses a winbridge-named file missing the ownership marker', () {
      final path = writeFile(
        p.join(expectedDir(home), 'winbridge-crafted.desktop'),
        '[Desktop Entry]\nName=crafted\nExec="/bin/true"\n',
      );
      expect(
        () => store.removeOwnedFile(path),
        throwsA(isA<UsageFailure>()),
      );
      expect(File(path).existsSync(), isTrue);
    });

    test('a crafted file with the right name but no marker survives', () {
      // Exactly the shape an attacker who can drop a file in the
      // applications directory would try: the right prefix, the right
      // extension, everything but the one line that proves ownership.
      final path = writeFile(
        p.join(expectedDir(home), 'winbridge-passwd.desktop'),
        '[Desktop Entry]\nType=Application\nName=totally legit\n'
        'Exec="/etc/passwd"\n',
      );
      expect(() => store.removeOwnedFile(path), throwsA(isA<UsageFailure>()));
      expect(File(path).existsSync(), isTrue);
    });

    test('accepts the combination it demands: right name and the marker', () {
      final path = writeFile(
        p.join(expectedDir(home), 'winbridge-ok.desktop'),
        '[Desktop Entry]\nX-WinBridge=true\n',
      );
      store.removeOwnedFile(path);
      expect(File(path).existsSync(), isFalse);
    });

    test('a missing file is a clear usage error', () {
      final path = p.join(expectedDir(home), 'winbridge-ghost.desktop');
      expect(() => store.removeOwnedFile(path), throwsA(isA<UsageFailure>()));
    });
  });

  group('refreshDesktopDatabase', () {
    test('is a silent no-op when the tool is not on PATH', () async {
      final runner = RecordingProcessRunner();
      await refreshDesktopDatabase(
        tools: ToolResolver(environment: const {}),
        runner: runner,
        directory: expectedDir(home),
        output: silentOutput(),
      );
      expect(runner.calls, isEmpty);
    });

    test('runs the resolved tool against the applications directory', () async {
      final bin = tempDir('bin');
      final tool = writeExecutable(bin, 'update-desktop-database');
      final runner = RecordingProcessRunner();

      await refreshDesktopDatabase(
        tools: ToolResolver(environment: {'PATH': bin}),
        runner: runner,
        directory: expectedDir(home),
        output: silentOutput(),
      );

      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.executable, tool);
      expect(runner.calls.single.arguments, [expectedDir(home)]);
    });

    test('a non-zero exit is swallowed, not thrown', () async {
      final bin = tempDir('bin');
      writeExecutable(bin, 'update-desktop-database');
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(exitCode: 1),
      );

      await expectLater(
        refreshDesktopDatabase(
          tools: ToolResolver(environment: {'PATH': bin}),
          runner: runner,
          directory: expectedDir(home),
          output: silentOutput(),
        ),
        completes,
      );
    });
  });
}
