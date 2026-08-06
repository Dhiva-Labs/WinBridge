import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

void main() {
  late String home;
  late String pathDir;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
  });

  ToolResolver resolverWith({String? toolchainDir, String? path}) =>
      ToolResolver(environment: {
        'HOME': home,
        'PATH': path ?? pathDir,
        WinBridgeConfig.toolchainDirVariable: ?toolchainDir,
      });

  group('search order', () {
    test('WINBRIDGE_TOOLCHAIN_DIR wins over the cache and PATH', () {
      final override = tempDir('override');
      final expected = writeExecutable(p.join(override, 'go', 'bin'), 'go');
      writeExecutable(managedToolchainBin(home, 'go'), 'go');
      writeExecutable(pathDir, 'go');

      final tool = resolverWith(toolchainDir: override).resolve('go')!;
      expect(tool.path, expected);
      expect(tool.source, ToolSource.override);
    });

    test('the managed cache wins over PATH', () {
      final expected = writeExecutable(managedToolchainBin(home, 'go'), 'go');
      writeExecutable(pathDir, 'go');

      final tool = resolverWith().resolve('go')!;
      expect(tool.path, expected);
      expect(tool.source, ToolSource.managed);
    });

    test('PATH is the last resort', () {
      final expected = writeExecutable(pathDir, 'zig');
      final tool = resolverWith().resolve('zig')!;
      expect(tool.path, expected);
      expect(tool.source, ToolSource.path);
    });

    test('PATH order is preserved', () {
      final first = tempDir('path1');
      final second = tempDir('path2');
      final expected = writeExecutable(first, 'cc');
      writeExecutable(second, 'cc');

      final tool = resolverWith(path: '$first:$second').resolve('cc')!;
      expect(tool.path, expected);
    });

    test('resolved paths are absolute', () {
      writeExecutable(managedToolchainBin(home, 'go'), 'go');
      expect(p.isAbsolute(resolverWith().resolve('go')!.path), isTrue);
    });
  });

  group('search path construction', () {
    test('only */bin subdirectories are searched', () {
      final override = tempDir('override');
      // A toolchain laid out without a bin/ directory contributes nothing.
      writeFile(p.join(override, 'go', 'go'));
      writeExecutable(p.join(override, 'zig', 'bin'), 'zig');

      final resolver = resolverWith(toolchainDir: override);
      expect(
        resolver.searchDirectories,
        contains(p.join(override, 'zig', 'bin')),
      );
      expect(resolver.resolve('go'), isNull);
    });

    test('bin directories are searched in sorted order', () {
      final override = tempDir('override');
      for (final name in ['zzz', 'aaa', 'mmm']) {
        writeExecutable(p.join(override, name, 'bin'), 'tool');
      }
      final resolver = resolverWith(toolchainDir: override);
      expect(
        resolver.searchDirectories.take(3),
        [
          p.join(override, 'aaa', 'bin'),
          p.join(override, 'mmm', 'bin'),
          p.join(override, 'zzz', 'bin'),
        ],
      );
    });

    test('relative PATH entries are ignored', () {
      final resolver = resolverWith(path: 'relative/bin::$pathDir');
      expect(resolver.searchDirectories, [pathDir]);
    });

    test('a relative WINBRIDGE_TOOLCHAIN_DIR is ignored', () {
      final resolver = resolverWith(toolchainDir: 'some/where');
      expect(
        resolver.searchEntries.any((e) => e.source == ToolSource.override),
        isFalse,
      );
    });

    test('duplicate directories appear once', () {
      final resolver = resolverWith(path: '$pathDir:$pathDir:$pathDir/');
      expect(resolver.searchDirectories, [pathDir]);
    });

    test('XDG_CACHE_HOME relocates the managed root', () {
      final cache = tempDir('xdg');
      final bin = p.join(cache, 'winbridge', 'toolchains', 'go', 'bin');
      final expected = writeExecutable(bin, 'go');

      final resolver = ToolResolver(environment: {
        'HOME': home,
        'XDG_CACHE_HOME': cache,
        'PATH': pathDir,
      });
      expect(resolver.resolve('go')!.path, expected);
    });

    test('an environment without HOME still searches PATH', () {
      final expected = writeExecutable(pathDir, 'go');
      final resolver = ToolResolver(environment: {'PATH': pathDir});
      expect(resolver.resolve('go')!.path, expected);
    });

    test('an empty environment resolves nothing', () {
      final resolver = ToolResolver(environment: const {});
      expect(resolver.searchDirectories, isEmpty);
      expect(resolver.resolve('go'), isNull);
    });
  });

  group('candidates', () {
    test('non-executable files are skipped', () {
      writeFile(p.join(managedToolchainBin(home, 'go'), 'go'), 'not runnable');
      final expected = writeExecutable(pathDir, 'go');
      expect(resolverWith().resolve('go')!.path, expected);
    });

    test('directories are skipped', () {
      final bin = managedToolchainBin(home, 'go');
      writeFile(p.join(bin, 'go', 'placeholder'));
      final expected = writeExecutable(pathDir, 'go');
      expect(resolverWith().resolve('go')!.path, expected);
    });

    test('resolveAny takes the first name that resolves', () {
      writeExecutable(pathDir, 'gcc');
      final resolver = resolverWith();
      expect(resolver.resolveAny(['zig', 'gcc'])!.name, 'gcc');
      expect(resolver.resolveAny(['nope', 'nothing']), isNull);
    });

    test('an unknown tool resolves to null', () {
      expect(resolverWith().resolve('definitely-not-installed'), isNull);
    });
  });

  group('failures', () {
    test('requirePath throws ToolNotFound listing what was searched', () {
      final resolver = resolverWith();
      expect(
        () => resolver.requirePath('zig', reason: 'compiles C for Windows'),
        throwsA(
          isA<ToolNotFound>()
              .having((e) => e.message, 'message', contains('zig'))
              .having((e) => e.message, 'message',
                  contains('compiles C for Windows'))
              .having((e) => e.details, 'details', contains(pathDir))
              .having((e) => e.exitCode, 'exitCode', 1),
        ),
      );
    });

    test('requireAny reports every candidate', () {
      expect(
        () => resolverWith().requireAny(['zig', 'x86_64-w64-mingw32-gcc']),
        throwsA(isA<ToolNotFound>().having(
          (e) => e.message,
          'message',
          allOf(contains('zig'), contains('x86_64-w64-mingw32-gcc')),
        )),
      );
    });

    test('a path is not an acceptable tool name', () {
      final resolver = resolverWith();
      expect(() => resolver.resolve('../../bin/anything'), throwsArgumentError);
      expect(() => resolver.resolve('/usr/bin/anything'), throwsArgumentError);
      expect(() => resolver.resolve(''), throwsArgumentError);
    });
  });
}
