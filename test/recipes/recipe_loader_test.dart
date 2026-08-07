import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/recipes/recipe.dart';
import 'package:winbridge/src/recipes/recipe_loader.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

Map<String, dynamic> recipeJson(String id, {String sha256 = 'a', bool valid = true}) {
  final hash = valid ? (sha256 * 64).substring(0, 64) : 'not-a-hash';
  return {
    'id': id,
    'match': {'sha256': hash},
  };
}

void writeRecipe(String directory, String fileName, Map<String, dynamic> json) {
  writeFile(p.join(directory, fileName), jsonEncode(json));
}

void main() {
  late String bundled;
  late String user;

  setUp(() {
    bundled = tempDir('bundled-recipes');
    user = tempDir('user-recipes');
  });

  group('loadAll', () {
    test('loads every valid recipe from the bundled directory', () {
      writeRecipe(bundled, 'a.json', recipeJson('a', sha256: 'a'));
      writeRecipe(bundled, 'b.json', recipeJson('b', sha256: 'b'));

      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: null).loadAll();
      expect(loaded.errors, isEmpty);
      expect(loaded.recipes.map((r) => r.id), ['a', 'b']);
      expect(loaded.recipes.every((r) => r.sourceKind == RecipeSourceKind.bundled),
          isTrue);
    });

    test('a user recipe overrides a bundled one sharing its id', () {
      writeRecipe(bundled, 'a.json', recipeJson('a', sha256: 'a'));
      writeRecipe(user, 'a.json', recipeJson('a', sha256: 'b'));

      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: user).loadAll();
      expect(loaded.errors, isEmpty);
      expect(loaded.recipes, hasLength(1));
      expect(loaded.recipes.single.sourceKind, RecipeSourceKind.user);
      expect(loaded.recipes.single.match.sha256, ('b' * 64));
    });

    test('a broken recipe is reported and skipped, not thrown', () {
      writeRecipe(bundled, 'good.json', recipeJson('good', sha256: 'a'));
      writeFile(p.join(bundled, 'bad.json'), '{ not json');
      writeRecipe(
          bundled, 'invalid.json', {'id': '-nope', 'match': <String, dynamic>{}});

      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: null).loadAll();
      expect(loaded.recipes.map((r) => r.id), ['good']);
      expect(loaded.errors, hasLength(2));
      expect(loaded.errors.map((e) => p.basename(e.path)),
          containsAll(['bad.json', 'invalid.json']));
    });

    test('a non-object JSON document is reported, not thrown', () {
      writeFile(p.join(bundled, 'array.json'), '[1, 2, 3]');
      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: null).loadAll();
      expect(loaded.recipes, isEmpty);
      expect(loaded.errors.single.messages.join(), contains('JSON object'));
    });

    test('ignores non-.json files', () {
      writeRecipe(bundled, 'a.json', recipeJson('a', sha256: 'a'));
      writeFile(p.join(bundled, 'README.md'), '# not a recipe');
      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: null).loadAll();
      expect(loaded.recipes, hasLength(1));
      expect(loaded.errors, isEmpty);
    });

    test('a missing directory is not an error', () {
      final loaded = RecipeLoader(
        bundledDirectory: p.join(bundled, 'does-not-exist'),
        userDirectory: null,
      ).loadAll();
      expect(loaded.recipes, isEmpty);
      expect(loaded.errors, isEmpty);
    });

    test('null directories are not an error', () {
      final loaded =
          RecipeLoader(bundledDirectory: null, userDirectory: null).loadAll();
      expect(loaded.recipes, isEmpty);
      expect(loaded.errors, isEmpty);
    });

    test('results are sorted by id', () {
      writeRecipe(bundled, 'z.json', recipeJson('z-app', sha256: 'a'));
      writeRecipe(bundled, 'a.json', recipeJson('a-app', sha256: 'b'));
      final loaded =
          RecipeLoader(bundledDirectory: bundled, userDirectory: null).loadAll();
      expect(loaded.recipes.map((r) => r.id), ['a-app', 'z-app']);
    });
  });

  group('locateBundled', () {
    test('an explicit override wins when the directory exists', () {
      final located = RecipeLoader.locateBundled(
        environment: {bundledRecipesDirVariable: bundled},
      );
      expect(located, p.normalize(bundled));
    });

    test('an override pointing nowhere real is not used', () {
      final located = RecipeLoader.locateBundled(
        environment: {bundledRecipesDirVariable: p.join(bundled, 'nope')},
      );
      expect(located, isNot(p.join(bundled, 'nope')));
    });
  });

  group('locateUser', () {
    test('sits under dataRoot, a sibling of prefixes', () {
      final config = WinBridgeConfig(environment: {'HOME': '/home/dev'});
      final located = RecipeLoader.locateUser(config);
      expect(located, p.join(config.dataRoot!, 'recipes'));
      expect(located, p.join('/home/dev', '.local', 'share', 'winbridge', 'recipes'));
    });

    test('null when there is no data root', () {
      final config = WinBridgeConfig(environment: const {});
      expect(RecipeLoader.locateUser(config), isNull);
    });
  });
}
