import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/cli/runner.dart';
import 'package:winbridge/src/recipes/recipes.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// End-to-end coverage through the real `winbridge recipe` CLI wiring, built
/// by hand here exactly the way the composition root will:
/// `runner.addCommand(RecipeCommand())` is the one line
/// `lib/src/cli/runner.dart` needs — see the M5 report. This proves the
/// command behaves once that line lands, without touching that file (the
/// same pattern `test/desktop/desktop_command_test.dart` documents).
void main() {
  late String home;

  setUp(() => home = tempDir('home'));

  WinBridgeRunner buildRunner(
    StringBuffer out, {
    String? recipesDir,
    Map<String, String> extraEnv = const {},
  }) {
    // `sha256sum` is not something WinBridge bundles — fingerprinting shells
    // out to the real one, the same way `AssetCache` does for its own
    // downloads. Real $PATH is used here specifically to reach it; nothing
    // else on it can be found because a fresh, isolated $HOME with no managed
    // toolchains means nothing else WinBridge looks for is resolvable through
    // it by accident.
    final config = WinBridgeConfig(environment: {
      'HOME': home,
      'PATH': Platform.environment['PATH'] ?? '',
      bundledRecipesDirVariable: ?recipesDir,
      ...extraEnv,
    });
    return WinBridgeRunner(config: config, out: out, err: out);
  }

  final sha256sumAvailable =
      ToolResolver(config: WinBridgeConfig()).resolve('sha256sum') != null;

  String writeRecipeFile(String dir, String fileName, Map<String, dynamic> json) =>
      writeFile(p.join(dir, fileName), jsonEncode(json));

  group('recipe list', () {
    test('reports nothing loaded when there is nothing to load', () async {
      final out = StringBuffer();
      final recipesDir = tempDir('recipes-empty');
      final code =
          await buildRunner(out, recipesDir: recipesDir).execute(['recipe', 'list']);
      expect(code, 0);
      expect(out.toString(), contains('no recipes loaded'));
    });

    test('lists a valid recipe and warns about a broken one', () async {
      final recipesDir = tempDir('recipes');
      writeRecipeFile(recipesDir, 'good.json', {
        'id': 'good-app',
        'match': {'sha256': 'a' * 64},
      });
      writeFile(p.join(recipesDir, 'bad.json'), '{ not json');

      final out = StringBuffer();
      final code =
          await buildRunner(out, recipesDir: recipesDir).execute(['recipe', 'list']);
      expect(code, 0);
      expect(out.toString(), contains('good-app'));
      expect(out.toString(), contains('bad.json'));
      expect(out.toString(), contains('warning:'));
    });
  });

  group('recipe show', () {
    test('rejects the wrong number of arguments', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['recipe', 'show']);
      expect(code, 2);
    });

    test(
      'reports no match against an empty recipe set',
      () async {
        final exe = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');
        final out = StringBuffer();
        final code = await buildRunner(out, recipesDir: tempDir('recipes-empty'))
            .execute(['recipe', 'show', exe]);
        expect(code, 0);
        expect(out.toString(), contains('no recipe matches'));
        // The fingerprint is still reported even with no match.
        expect(out.toString(),
            contains('b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'));
      },
      skip: sha256sumAvailable ? false : 'no sha256sum on PATH',
    );

    test(
      'reports the matching recipe and exactly what apply would do',
      () async {
        final exe = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');
        final recipesDir = tempDir('recipes');
        writeRecipeFile(recipesDir, 'match.json', {
          'id': 'hello-app',
          'match': {
            'sha256':
                'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
          },
          'apply': {
            'tricks': ['corefonts'],
            'dllOverrides': {'d3d9': 'n'},
            'dxvk': true,
          },
          'notes': 'a test fixture, not a real app',
        });

        final out = StringBuffer();
        final code = await buildRunner(out, recipesDir: recipesDir)
            .execute(['recipe', 'show', exe]);
        expect(code, 0);
        expect(out.toString(), contains('hello-app'));
        expect(out.toString(), contains('sha256'));
        expect(out.toString(), contains('corefonts'));
        expect(out.toString(), contains('d3d9=n'));
        expect(out.toString(), contains('dxvk      yes'));
        expect(out.toString(), contains('a test fixture, not a real app'));
      },
      skip: sha256sumAvailable ? false : 'no sha256sum on PATH',
    );
  });

  group('recipe apply', () {
    test('rejects the wrong number of arguments', () async {
      final out = StringBuffer();
      final code = await buildRunner(out).execute(['recipe', 'apply']);
      expect(code, 2);
    });

    test(
      'fails cleanly, naming the sha256, when nothing matches',
      () async {
        final exe = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');
        final out = StringBuffer();
        final code = await buildRunner(out, recipesDir: tempDir('recipes-empty'))
            .execute(['recipe', 'apply', exe]);
        expect(code, 1);
        expect(out.toString(), contains('no recipe matches'));
        expect(out.toString(), contains('b94d27b9'));
      },
      skip: sha256sumAvailable ? false : 'no sha256sum on PATH',
    );

    test(
      'a matched recipe with nothing to apply reports that and touches no '
      'wine runtime at all',
      () async {
        final exe = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');
        final recipesDir = tempDir('recipes');
        writeRecipeFile(recipesDir, 'match.json', {
          'id': 'known-working',
          'match': {
            'sha256':
                'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
          },
        });

        final out = StringBuffer();
        final code = await buildRunner(out, recipesDir: recipesDir)
            .execute(['recipe', 'apply', exe]);
        expect(code, 0);
        expect(out.toString(), contains('known-working'));
        expect(out.toString(), contains('nothing to apply'));
        // No prefix was ever created — nothing to apply means nothing runs.
        expect(
          Directory(p.join(home, '.local', 'share', 'winbridge', 'prefixes'))
              .existsSync(),
          isFalse,
        );
      },
      skip: sha256sumAvailable ? false : 'no sha256sum on PATH',
    );

    test('--prefix is honoured for naming, even with nothing to apply',
        () async {
      final exe = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');
      final recipesDir = tempDir('recipes');
      writeRecipeFile(recipesDir, 'match.json', {
        'id': 'known-working',
        'match': {
          'sha256':
              'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        },
      });

      final out = StringBuffer();
      final code = await buildRunner(out, recipesDir: recipesDir)
          .execute(['recipe', 'apply', exe, '--prefix', 'myprefix']);
      expect(code, 0);
      expect(out.toString(), contains(p.join('prefixes', 'myprefix')));
    },
        skip: sha256sumAvailable ? false : 'no sha256sum on PATH');
  });
}
