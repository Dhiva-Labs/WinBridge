import 'fingerprint.dart';
import 'recipe.dart';

/// The recipe [matchRecipe] found, if any, and which of its two ways of
/// matching actually fired.
class RecipeMatchResult {
  const RecipeMatchResult({this.recipe, this.matchedBy});

  const RecipeMatchResult.none() : this();

  final Recipe? recipe;
  final MatchKind? matchedBy;

  bool get found => recipe != null;
}

/// Finds the recipe for [fingerprint] among [recipes].
///
/// sha256 is authoritative: every sha256-keyed recipe is checked before any
/// fileName+sizeBytes one, regardless of list order, so a hash match always
/// wins over the exact-match fallback. Only when nothing hashes to a known
/// recipe does the fallback get a look — see docs/recipes.md for why the
/// fallback exists at all (an installer nobody has fingerprinted yet, but
/// whose name and size someone already recognises).
RecipeMatchResult matchRecipe(
  InstallerFingerprint fingerprint,
  Iterable<Recipe> recipes,
) {
  for (final recipe in recipes) {
    if (recipe.match.kind == MatchKind.sha256 &&
        recipe.match.sha256 == fingerprint.sha256) {
      return RecipeMatchResult(recipe: recipe, matchedBy: MatchKind.sha256);
    }
  }
  for (final recipe in recipes) {
    if (recipe.match.kind == MatchKind.fileNameAndSize &&
        recipe.match.sizeBytes == fingerprint.sizeBytes &&
        _sameFileName(recipe.match.fileName!, fingerprint.fileName)) {
      return RecipeMatchResult(
        recipe: recipe,
        matchedBy: MatchKind.fileNameAndSize,
      );
    }
  }
  return const RecipeMatchResult.none();
}

/// Windows file names are case-insensitive, and installers are Windows
/// artifacts downloaded under all sorts of casing (`Setup.exe`, `setup.EXE`).
/// The fallback match is already the weaker of the two mechanisms; being
/// case-sensitive on top of that would just make it miss for no real safety
/// gain — nothing here reaches a path or a shell, it is a plain string
/// comparison.
bool _sameFileName(String a, String b) => a.toLowerCase() == b.toLowerCase();
