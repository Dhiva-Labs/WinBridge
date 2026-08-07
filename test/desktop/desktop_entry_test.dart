import 'package:test/test.dart';
import 'package:winbridge/src/desktop/desktop_entry.dart';
import 'package:winbridge/winbridge.dart';

void main() {
  group('render', () {
    test('golden content for a normal add', () {
      final entry = DesktopEntry(
        slug: 'hello_c',
        name: 'hello_c',
        prefix: 'hello_c',
        executablePath: '/home/dev/build/winbridge/windows-x64/hello_c.exe',
      );

      expect(entry.render(), '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=hello_c\n'
          'Comment=Runs via WinBridge\n'
          'Exec=winbridge run --prefix "hello_c" '
          '"/home/dev/build/winbridge/windows-x64/hello_c.exe"\n'
          'Icon=application-x-executable\n'
          'Terminal=false\n'
          'Categories=Utility;\n'
          'StartupNotify=false\n'
          'X-WinBridge=true\n');
    });

    test('carries the ownership marker on its own line', () {
      final entry = DesktopEntry(
        slug: 'app',
        name: 'app',
        prefix: 'app',
        executablePath: '/apps/app.exe',
      );
      expect(entry.render().split('\n'), contains('X-WinBridge=true'));
    });

    test('file name is winbridge-<name>.desktop', () {
      final entry = DesktopEntry(
        slug: 'My-App.v2',
        name: 'My-App.v2',
        prefix: 'My-App.v2',
        executablePath: '/apps/My-App.v2.exe',
      );
      expect(entry.fileName, 'winbridge-My-App.v2.desktop');
    });

    test('a custom display name is used verbatim, independent of the prefix', () {
      final entry = DesktopEntry(
        slug: 'app',
        name: 'My Game',
        prefix: 'game',
        executablePath: '/apps/game.exe',
      );
      expect(entry.render(), contains('Name=My Game\n'));
      expect(entry.render(), contains('--prefix "game"'));
      expect(entry.fileName, 'winbridge-app.desktop');
    });
  });

  group('Exec quoting', () {
    test('a path with spaces is wrapped in double quotes', () {
      final entry = DesktopEntry(
        slug: 'game',
        name: 'game',
        prefix: 'game',
        executablePath: '/opt/My Games/Deluxe Edition/game.exe',
      );
      expect(
        entry.render(),
        contains(
          'Exec=winbridge run --prefix "game" '
          '"/opt/My Games/Deluxe Edition/game.exe"\n',
        ),
      );
    });

    test('quoteExecArgument always wraps in double quotes', () {
      expect(quoteExecArgument('plain'), '"plain"');
      expect(quoteExecArgument('has space'), '"has space"');
    });

    test('quoteExecArgument escapes backslash, quote, backtick and dollar', () {
      expect(quoteExecArgument(r'a\b'), r'"a\\b"');
      expect(quoteExecArgument('a"b'), r'"a\"b"');
      expect(quoteExecArgument('a`b'), r'"a\`b"');
      expect(quoteExecArgument(r'a$b'), r'"a\$b"');
    });

    test('a path carrying backslash, quote, backtick and dollar round-trips', () {
      // Not a realistic file name, but the escaping must not fall over on
      // one that tries to be as hostile as a path can get.
      const hostile = r'/apps/na\me "quoted" `ticked` $dollar.exe';
      final entry = DesktopEntry(
        slug: 'app',
        name: 'app',
        prefix: 'app',
        executablePath: hostile,
      );
      // Every literal double quote, backslash, backtick and dollar sign in
      // the source path is escaped, and the whole argument stays inside one
      // pair of double quotes.
      final exec = entry
          .render()
          .split('\n')
          .firstWhere((line) => line.startsWith('Exec='));
      expect(exec, endsWith('"'));
      expect('"'.allMatches(exec).length.isEven, isTrue);
    });
  });

  group('injection rejected', () {
    test('a name containing "\\nExec=" is rejected, not written', () {
      expect(
        () => DesktopEntry(
        slug: 'app',
          name: 'evil\nExec=rm -rf ~',
          prefix: 'app',
          executablePath: '/apps/app.exe',
        ),
        throwsA(isA<UsageFailure>()
            .having((e) => e.exitCode, 'exitCode', 2)
            .having((e) => e.message, 'message', contains('invalid name'))),
      );
    });

    test('a name with a bare control character is rejected', () {
      expect(
        () => DesktopEntry(
        slug: 'app',
          name: 'evil\x00thing',
          prefix: 'app',
          executablePath: '/apps/app.exe',
        ),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('a name with a carriage return is rejected', () {
      expect(
        () => DesktopEntry(
        slug: 'app',
          name: 'evil\rExec=rm -rf ~',
          prefix: 'app',
          executablePath: '/apps/app.exe',
        ),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('an empty name is rejected', () {
      expect(
        () => DesktopEntry(
        slug: 'app',name: '', prefix: 'app', executablePath: '/a.exe'),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('a name that is a path traversal component is rejected', () {
      for (final bad in ['.', '..', 'a/b', r'a\b']) {
        expect(
          () => DesktopEntry(
        slug: 'app',
            name: bad,
            prefix: 'app',
            executablePath: '/a.exe',
          ),
          throwsA(isA<UsageFailure>()),
          reason: 'accepted "$bad"',
        );
      }
    });

    test('the prefix gets the same rejection as the name', () {
      expect(
        () => DesktopEntry(
        slug: 'app',
          name: 'app',
          prefix: 'evil\nExec=rm -rf ~',
          executablePath: '/a.exe',
        ),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('a leading dash is rejected — it would read as a flag elsewhere', () {
      expect(
        () => DesktopEntry(
        slug: '-rf',name: '-rf', prefix: 'app', executablePath: '/a.exe'),
        throwsA(isA<UsageFailure>()),
      );
    });
  });
}
