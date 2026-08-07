import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/winbridge.dart';

import 'recipe.dart';

/// Explicit override for where bundled recipes live, the same shape as
/// `WINBRIDGE_TOOLCHAIN_DIR`/`WINBRIDGE_VM_CONFIG`: packaging's answer for
/// "where did you actually put the data directory", used before any
/// best-effort guessing.
const bundledRecipesDirVariable = 'WINBRIDGE_RECIPES_DIR';

/// One recipe file that could not be loaded, with every validation problem
/// found — never just the first one.
class RecipeLoadError {
  const RecipeLoadError({
    required this.path,
    required this.sourceKind,
    required this.messages,
  });

  final String path;
  final RecipeSourceKind sourceKind;
  final List<String> messages;
}

/// The result of a load: every recipe that validated, and every file that
/// did not. A broken recipe is reported, never silently dropped and never
/// partially applied — see docs/recipes.md.
class LoadedRecipes {
  const LoadedRecipes({required this.recipes, required this.errors});

  /// Sorted by id. A `user` recipe replaces a `bundled` one sharing its id.
  final List<Recipe> recipes;

  final List<RecipeLoadError> errors;
}

/// Loads recipes from the bundled `recipes/` tree and the user's own
/// `~/.local/share/winbridge/recipes` (XDG aware), merging by id with the
/// user directory winning. Never executes anything it reads — every recipe is
/// JSON, parsed and validated, nothing more.
class RecipeLoader {
  const RecipeLoader({required this.bundledDirectory, required this.userDirectory});

  /// Null when nothing was found — see [locateBundled]. Not an error: a
  /// machine with only user recipes still works.
  final String? bundledDirectory;

  /// Null when there is nowhere to look — no `$HOME`/`$XDG_DATA_HOME`. Same
  /// treatment as [bundledDirectory].
  final String? userDirectory;

  /// Where the bundled `recipes/` tree lives, first hit wins:
  ///
  ///  1. [bundledRecipesDirVariable], if it points at a directory that
  ///     exists — packaging's explicit answer.
  ///  2. `recipes/` beside the running executable — the layout of a packaged
  ///     install that ships the binary and its data directory together.
  ///  3. `recipes/` at the root of a source checkout, resolved relative to
  ///     `bin/winbridge.dart` — what `dart run bin/winbridge.dart` sees.
  ///
  /// Returns null rather than guessing further; a caller that needs the
  /// bundled tree to be found reports that plainly instead of silently
  /// running with zero bundled recipes.
  static String? locateBundled({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;

    final override = env[bundledRecipesDirVariable];
    if (override != null && override.isNotEmpty) {
      final resolved = p.normalize(p.absolute(override));
      return Directory(resolved).existsSync() ? resolved : null;
    }

    final besideExecutable = p.normalize(
      p.join(p.dirname(Platform.resolvedExecutable), 'recipes'),
    );
    if (Directory(besideExecutable).existsSync()) return besideExecutable;

    try {
      final scriptDir = p.dirname(Platform.script.toFilePath());
      final besideScript = p.normalize(p.join(scriptDir, '..', 'recipes'));
      if (Directory(besideScript).existsSync()) return besideScript;
    } on UnsupportedError {
      // Platform.script has no meaningful file path (e.g. some embedders);
      // there is nothing left to try.
    }

    return null;
  }

  /// `~/.local/share/winbridge/recipes`, honouring `XDG_DATA_HOME` — a
  /// sibling of [WinBridgeConfig.prefixRoot] under the same data root. Null
  /// when [WinBridgeConfig.dataRoot] is, for the same reason: no `$HOME`.
  static String? locateUser(WinBridgeConfig config) {
    final root = config.dataRoot;
    return root == null ? null : p.join(root, 'recipes');
  }

  LoadedRecipes loadAll() {
    final byId = <String, Recipe>{};
    final errors = <RecipeLoadError>[];

    void loadDirectory(String? directory, RecipeSourceKind kind) {
      if (directory == null) return;
      final dir = Directory(directory);
      if (!dir.existsSync()) return;

      final files = [
        for (final entry in dir.listSync(followLinks: false))
          if (entry is File && entry.path.endsWith('.json')) entry,
      ]..sort((a, b) => a.path.compareTo(b.path));

      for (final file in files) {
        final Object? decoded;
        try {
          decoded = jsonDecode(file.readAsStringSync());
        } on FormatException catch (error) {
          errors.add(RecipeLoadError(
            path: file.path,
            sourceKind: kind,
            messages: ['not valid JSON: ${error.message}'],
          ));
          continue;
        } on FileSystemException catch (error) {
          errors.add(RecipeLoadError(
            path: file.path,
            sourceKind: kind,
            messages: [error.osError?.message ?? 'could not be read'],
          ));
          continue;
        }

        if (decoded is! Map<String, dynamic>) {
          errors.add(RecipeLoadError(
            path: file.path,
            sourceKind: kind,
            messages: ['must contain a JSON object'],
          ));
          continue;
        }

        try {
          final recipe = Recipe.fromJson(
            decoded,
            sourcePath: file.path,
            sourceKind: kind,
          );
          byId[recipe.id] = recipe;
        } on RecipeValidationError catch (error) {
          errors.add(RecipeLoadError(
            path: file.path,
            sourceKind: kind,
            messages: error.messages,
          ));
        }
      }
    }

    loadDirectory(bundledDirectory, RecipeSourceKind.bundled);
    loadDirectory(userDirectory, RecipeSourceKind.user);

    final recipes = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return LoadedRecipes(recipes: recipes, errors: errors);
  }
}
