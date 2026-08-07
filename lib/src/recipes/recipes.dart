/// Surface for the M5 compatibility-recipe engine.
///
/// One thing needs wiring outside this directory, and it is not done here —
/// `lib/src/recipes/` is not allowed to import `lib/src/cli/toolchain_setup.dart`
/// or `lib/src/cli/runner.dart`, only the other way around:
///
///  * [RecipeCommand] belongs alongside `PrefixCommand`/`RunCommand`/
///    `VmCommand` in `WinBridgeRunner`'s constructor, via `addCommand`.
library;

export 'fingerprint.dart';
export 'recipe.dart';
export 'recipe_apply.dart';
export 'recipe_command.dart' show RecipeCommand;
export 'recipe_loader.dart';
export 'recipe_matcher.dart';
