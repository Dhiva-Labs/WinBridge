import 'package:test/test.dart';
import 'package:winbridge/src/recipes/fingerprint.dart';
import 'package:winbridge/src/recipes/recipe.dart';
import 'package:winbridge/src/recipes/recipe_matcher.dart';

const _sha = '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2';
const _otherSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Recipe sha256Recipe(String id, String sha256) => Recipe(
      id: id,
      match: RecipeMatch.sha256(sha256),
      apply: RecipeApply.empty,
      notes: null,
      source: null,
      sourcePath: '$id.json',
      sourceKind: RecipeSourceKind.bundled,
    );

Recipe fileNameRecipe(String id, {required String fileName, required int sizeBytes}) =>
    Recipe(
      id: id,
      match: RecipeMatch.fileNameAndSize(fileName: fileName, sizeBytes: sizeBytes),
      apply: RecipeApply.empty,
      notes: null,
      source: null,
      sourcePath: '$id.json',
      sourceKind: RecipeSourceKind.bundled,
    );

void main() {
  const fingerprint = InstallerFingerprint(
    sha256: _sha,
    fileName: 'Setup.exe',
    sizeBytes: 1000,
  );

  test('matches by sha256', () {
    final recipe = sha256Recipe('a', _sha);
    final result = matchRecipe(fingerprint, [recipe]);
    expect(result.found, isTrue);
    expect(result.recipe, recipe);
    expect(result.matchedBy, MatchKind.sha256);
  });

  test('falls back to fileName+sizeBytes when no sha256 recipe matches', () {
    final recipe = fileNameRecipe('b', fileName: 'Setup.exe', sizeBytes: 1000);
    final result = matchRecipe(fingerprint, [recipe]);
    expect(result.found, isTrue);
    expect(result.recipe, recipe);
    expect(result.matchedBy, MatchKind.fileNameAndSize);
  });

  test('fileName match is case-insensitive', () {
    final recipe = fileNameRecipe('b', fileName: 'SETUP.EXE', sizeBytes: 1000);
    final result = matchRecipe(fingerprint, [recipe]);
    expect(result.found, isTrue);
  });

  test('fileName match requires the exact size too', () {
    final recipe = fileNameRecipe('b', fileName: 'Setup.exe', sizeBytes: 999);
    expect(matchRecipe(fingerprint, [recipe]).found, isFalse);
  });

  test('sha256 beats fileName even when the fallback recipe is listed first',
      () {
    final fallback =
        fileNameRecipe('fallback', fileName: 'Setup.exe', sizeBytes: 1000);
    final authoritative = sha256Recipe('authoritative', _sha);
    final result = matchRecipe(fingerprint, [fallback, authoritative]);
    expect(result.recipe, authoritative);
    expect(result.matchedBy, MatchKind.sha256);
  });

  test('sha256 beats fileName regardless of load order (authoritative first)',
      () {
    final fallback =
        fileNameRecipe('fallback', fileName: 'Setup.exe', sizeBytes: 1000);
    final authoritative = sha256Recipe('authoritative', _sha);
    final result = matchRecipe(fingerprint, [authoritative, fallback]);
    expect(result.recipe, authoritative);
    expect(result.matchedBy, MatchKind.sha256);
  });

  test('a sha256 recipe for a different hash does not suppress a fileName '
      'fallback that does match', () {
    final unrelated = sha256Recipe('unrelated', _otherSha);
    final fallback =
        fileNameRecipe('fallback', fileName: 'Setup.exe', sizeBytes: 1000);
    final result = matchRecipe(fingerprint, [unrelated, fallback]);
    expect(result.recipe, fallback);
    expect(result.matchedBy, MatchKind.fileNameAndSize);
  });

  test('no match when nothing lines up', () {
    final recipe = sha256Recipe('a', _otherSha);
    final result = matchRecipe(fingerprint, [recipe]);
    expect(result.found, isFalse);
    expect(result.recipe, isNull);
    expect(result.matchedBy, isNull);
  });

  test('an empty recipe list never matches', () {
    expect(matchRecipe(fingerprint, const []).found, isFalse);
  });
}
