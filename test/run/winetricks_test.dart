import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/run/winetricks.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

void main() {
  test('the pin names a tagged release with a checksum', () {
    expect(pinnedWinetricks.version, '20260125');
    expect(pinnedWinetricks.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(pinnedWinetricks.url,
        startsWith('https://raw.githubusercontent.com/Winetricks/winetricks/'));
    expect(pinnedWinetricks.url, contains(pinnedWinetricks.version),
        reason: 'pinned to a tag, not a moving branch');
    expect(pinnedWinetricks.url, isNot(contains('master')));
    expect(pinnedWinetricks.executable, isTrue);
    expect(pinnedWinetricks.isArchive, isFalse);
  });

  // A verb reaches an argument vector, so it gets the same up-front check as
  // every other externally supplied token in this codebase.
  group('verb validation', () {
    test('accepts the shapes winetricks actually uses', () {
      for (final verb in [
        'corefonts',
        'vcrun2019',
        'dotnet48',
        'list-installed',
        'd3dx9_43',
        'gdiplus_winxp',
        'faudio1901',
        'python2.7',
        'nocrashdialog',
        'mfc42',
        'l3codec+',
      ]) {
        expect(WinetricksVerb.isValid(verb), isTrue, reason: verb);
        expect(WinetricksVerb.parse(verb).value, verb);
      }
    });

    test('refuses anything that could turn into another command', () {
      for (final bad in [
        'corefonts; rm -rf /',
        'corefonts && id',
        r'$(whoami)',
        '`id`',
        'core fonts',
        '--prefix=/etc',
        '-rf',
        '../../etc/passwd',
        'a/b',
        r'a\b',
        'CoreFonts',
        'verb|pipe',
        'verb>out',
        'verb\nsecond',
        '',
      ]) {
        expect(WinetricksVerb.isValid(bad), isFalse, reason: 'accepted "$bad"');
        expect(
          () => WinetricksVerb.parse(bad),
          throwsA(isA<UsageFailure>()
              .having((e) => e.exitCode, 'exitCode', 2)),
          reason: bad,
        );
      }
    });

    test('is anchored, so a newline cannot smuggle a second verb', () {
      expect(WinetricksVerb.isValid('corefonts\nrm'), isFalse);
      expect(WinetricksVerb.isValid('corefonts\n'), isFalse);
      expect(WinetricksVerb.isValid('\ncorefonts'), isFalse);
    });
  });

  group('environment', () {
    final wine = ResolvedWine(
      binary: '/rt/bin/wine',
      source: WineSource.managed,
      runtimeDirectory: '/rt',
    );
    final prefix = AppPrefix(name: 'game', path: '/prefixes/game');

    test('points winetricks at our prefix and our wine', () {
      final env = Winetricks.environmentFor(
        prefix: prefix,
        wine: wine,
        parentPath: '/usr/bin',
      );
      expect(env['WINEPREFIX'], '/prefixes/game');
      expect(env['WINE'], '/rt/bin/wine');
      expect(env['WINESERVER'], '/rt/bin/wineserver');
    });

    test('puts our wine ahead of anything on the inherited PATH', () {
      // winetricks shells out to `wine`, `wineboot` and `wineserver` by name;
      // without this it would find a system Wine, or none, and operate on the
      // prefix with a different build than the one that made it.
      final env = Winetricks.environmentFor(
        prefix: prefix,
        wine: wine,
        parentPath: '/usr/bin:/bin',
      );
      expect(env['PATH'], '/rt/bin:/usr/bin:/bin');
    });

    test('copes with an empty inherited PATH', () {
      final env = Winetricks.environmentFor(
        prefix: prefix,
        wine: wine,
        parentPath: '',
      );
      expect(env['PATH'], '/rt/bin');
    });

    test('quietens Wine unless asked not to', () {
      expect(
        Winetricks.environmentFor(
                prefix: prefix, wine: wine, parentPath: '')['WINEDEBUG'],
        '-all',
      );
      expect(
        Winetricks.environmentFor(
          prefix: prefix,
          wine: wine,
          parentPath: '',
          verbose: true,
        ).containsKey('WINEDEBUG'),
        isFalse,
      );
    });
  });

  test('the cached script lands beside the other managed assets', () {
    final home = tempDir('home');
    final config = WinBridgeConfig(environment: {'HOME': home});
    expect(
      p.join(config.managedRuntimeRoot!, pinnedWinetricks.name, 'winetricks'),
      endsWith(p.join('winbridge', 'runtimes', 'winetricks-20260125',
          'winetricks')),
    );
  });
}
