import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

void main() {
  late String home;
  late PrefixManager prefixes;

  setUp(() {
    home = tempDir('home');
    prefixes = PrefixManager(WinBridgeConfig(environment: {'HOME': home}));
  });

  String expectedRoot(String home) =>
      p.join(home, '.local', 'share', 'winbridge', 'prefixes');

  group('location', () {
    test('lives under XDG data, not the cache', () {
      // A prefix holds an installed app's registry and saved files. Putting it
      // in a cache directory invites a cleaner to delete someone's save games.
      final prefix = prefixes.forExecutable('/apps/game.exe');
      expect(prefix.path, p.join(expectedRoot(home), 'game'));
      expect(prefix.path, isNot(contains('.cache')));
    });

    test('honours XDG_DATA_HOME', () {
      final data = tempDir('xdg');
      final manager = PrefixManager(
        WinBridgeConfig(environment: {'HOME': home, 'XDG_DATA_HOME': data}),
      );
      expect(
        manager.forExecutable('/apps/game.exe').path,
        p.join(data, 'winbridge', 'prefixes', 'game'),
      );
    });

    test('fails cleanly with no home to work from', () {
      final manager = PrefixManager(WinBridgeConfig(environment: const {}));
      expect(
        () => manager.forExecutable('/apps/game.exe'),
        throwsA(isA<BuildFailure>()),
      );
    });
  });

  group('default name', () {
    test('is the executable stem, so each app gets its own world', () {
      expect(prefixes.forExecutable('/apps/Setup.exe').name, 'Setup');
      expect(prefixes.forExecutable('/apps/hello_c.exe').name, 'hello_c');
      expect(prefixes.forExecutable('/a/b/My-App.v2.exe').name, 'My-App.v2');
    });

    test('refuses a stem that is not a usable path component', () {
      // Rather than mangling it: the user is right there and can say what
      // they want.
      for (final path in ['/apps/..exe', '/apps/-rf.exe']) {
        expect(
          () => prefixes.forExecutable(path),
          throwsA(isA<UsageFailure>()
              .having((e) => e.details ?? '', 'details', contains('--prefix'))),
          reason: path,
        );
      }
    });
  });

  group('--prefix', () {
    test('accepts a plain name', () {
      final prefix = prefixes.byName('my-app', flag: '--prefix');
      expect(prefix.name, 'my-app');
      expect(prefix.path, p.join(expectedRoot(home), 'my-app'));
    });

    test('refuses anything that could escape the prefix root', () {
      for (final bad in [
        '..',
        '.',
        '../../etc',
        'a/b',
        r'a\b',
        '',
        '-rf',
        'a:b',
      ]) {
        expect(
          () => prefixes.byName(bad, flag: '--prefix'),
          throwsA(isA<UsageFailure>()),
          reason: 'accepted "$bad"',
        );
      }
    });

    test('a rejected name never yields a path outside the root', () {
      // The guarantee that matters, stated directly.
      for (final bad in ['../escape', '/etc/passwd', 'a/../../b']) {
        String? path;
        try {
          path = prefixes.byName(bad, flag: '--prefix').path;
        } on UsageFailure {
          continue;
        }
        expect(p.isWithin(expectedRoot(home), path), isTrue,
            reason: '"$bad" produced $path');
      }
    });
  });

  group('list', () {
    test('is empty before anything has run', () {
      expect(prefixes.list(), isEmpty);
    });

    test('reports existing prefixes by name, sorted', () {
      for (final name in ['zebra', 'apple', 'mango']) {
        writeFile(p.join(expectedRoot(home), name, 'system.reg'), '');
      }
      expect(prefixes.list().map((e) => e.name), ['apple', 'mango', 'zebra']);
    });

    test('exists reflects the directory', () {
      final prefix = prefixes.byName('game', flag: '--prefix');
      expect(prefix.exists, isFalse);
      writeFile(p.join(prefix.path, 'system.reg'), '');
      expect(prefix.exists, isTrue);
    });
  });
}
