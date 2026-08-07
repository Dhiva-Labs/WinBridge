import 'package:path/path.dart' as p;
import 'package:winbridge/src/cli/command.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/winbridge.dart';

import 'fingerprint.dart';
import 'recipe.dart';
import 'recipe_apply.dart';
import 'recipe_loader.dart';
import 'recipe_matcher.dart';

/// `winbridge recipe` — look up and apply known-good compatibility settings
/// (winetricks verbs, dll overrides, DXVK) for an installer, keyed by its
/// fingerprint. Has no action of its own; `show`, `apply` and `list` are its
/// subcommands. See docs/recipes.md.
class RecipeCommand extends WinBridgeCommand {
  RecipeCommand() {
    addSubcommand(RecipeShowCommand());
    addSubcommand(RecipeApplyCommand());
    addSubcommand(RecipeListCommand());
  }

  @override
  String get name => 'recipe';

  @override
  String get description =>
      'Look up and apply compatibility recipes for an installer.';
}

LoadedRecipes _load(WinBridgeConfig config) => RecipeLoader(
      bundledDirectory: RecipeLoader.locateBundled(environment: config.environment),
      userDirectory: RecipeLoader.locateUser(config),
    ).loadAll();

void _reportLoadErrors(Output output, List<RecipeLoadError> errors) {
  for (final error in errors) {
    output.warn('recipe ${error.path} (${error.sourceKind.label}) skipped:');
    for (final message in error.messages) {
      output.warn('  $message');
    }
  }
}

void _printApply(Output output, RecipeApply apply) {
  if (apply.isEmpty) {
    output.info('apply     nothing — documented as working with no changes');
    return;
  }
  if (apply.tricks.isNotEmpty) {
    output.info('tricks    ${apply.tricks.map((v) => v.value).join(' ')}');
  }
  if (apply.dllOverrides.isNotEmpty) {
    output.info('overrides '
        '${apply.dllOverrides.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  }
  if (apply.dxvk) {
    output.info('dxvk      yes');
  }
}

String _requireSinglePath(List<String> positional, String example) {
  if (positional.length != 1) {
    throw UsageFailure(
      'expected exactly one path to an installer',
      details: 'example: $example',
    );
  }
  return p.normalize(p.absolute(positional.single));
}

/// `winbridge recipe show <file.exe>` — fingerprint an installer and report
/// what would happen without touching anything.
class RecipeShowCommand extends WinBridgeCommand {
  @override
  String get name => 'show';

  @override
  String get description =>
      'Fingerprint an installer and show which recipe matches.';

  @override
  String get invocation => 'winbridge recipe show <file.exe>';

  @override
  Future<int> run() async {
    final output = context.output;
    final path =
        _requireSinglePath(argResults!.rest, 'winbridge recipe show Setup.exe');

    final loaded = _load(context.config);
    _reportLoadErrors(output, loaded.errors);

    final fingerprint = await fingerprintFile(
      path,
      tools: context.tools,
      runner: context.processes,
    );
    output.info('file      ${p.basename(path)}');
    output.info('sha256    ${fingerprint.sha256}');
    output.info('size      ${fingerprint.sizeBytes} bytes');
    output.blank();

    final match = matchRecipe(fingerprint, loaded.recipes);
    if (!match.found) {
      output.info('no recipe matches this installer.');
      output.info(
          'Fingerprint it yourself and contribute one — see docs/recipes.md.');
      return 0;
    }

    final recipe = match.recipe!;
    output.info(
        'recipe    ${recipe.id}  (matched by ${match.matchedBy!.label}, '
        '${recipe.sourceKind.label})');
    _printApply(output, recipe.apply);
    if (recipe.notes case final notes? when notes.isNotEmpty) {
      output.blank();
      output.info('notes     $notes');
    }
    if (recipe.source case final source? when source.isNotEmpty) {
      output.info('source    $source');
    }
    return 0;
  }
}

/// `winbridge recipe apply <file.exe> [--prefix <name>]` — apply the matched
/// recipe to a prefix. Failures stop at the step that hit them.
class RecipeApplyCommand extends WinBridgeCommand {
  RecipeApplyCommand() {
    argParser.addOption(
      'prefix',
      valueHelp: 'name',
      help: 'Which app prefix to apply the recipe to.\n'
          "Defaults to the executable's file name without .exe.",
    );
  }

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Apply the recipe matching an installer to its prefix.';

  @override
  String get invocation =>
      'winbridge recipe apply <file.exe> [--prefix <name>]';

  @override
  Future<int> run() async {
    final output = context.output;
    final path = _requireSinglePath(
        argResults!.rest, 'winbridge recipe apply Setup.exe');

    final loaded = _load(context.config);
    _reportLoadErrors(output, loaded.errors);

    final fingerprint = await fingerprintFile(
      path,
      tools: context.tools,
      runner: context.processes,
    );
    final match = matchRecipe(fingerprint, loaded.recipes);
    if (!match.found) {
      throw BuildFailure(
        'no recipe matches ${p.basename(path)}',
        details: 'sha256 ${fingerprint.sha256}\n'
            'run `winbridge recipe show ${p.basename(path)}` for details, or '
            'contribute a recipe — see docs/recipes.md',
      );
    }
    final recipe = match.recipe!;
    output.info('recipe    ${recipe.id}  (matched by ${match.matchedBy!.label})');

    final prefixes = PrefixManager(context.config);
    final requestedPrefix = argResults!.option('prefix');
    final prefix = requestedPrefix == null
        ? prefixes.forExecutable(path)
        : prefixes.byName(requestedPrefix, flag: '--prefix');
    output.info('prefix    ${prefix.path}');

    if (recipe.apply.isEmpty) {
      output.info(
          'nothing to apply — this recipe documents a known-working app '
          'with no special settings.');
      return 0;
    }

    final wine = await WineRuntime(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    ).resolveOrInstall();
    output.detail('wine      ${wine.binary} (${wine.source.label})');

    await RecipeApplier(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    ).apply(
      recipe: recipe,
      prefix: prefix,
      wine: wine,
      verbose: output.verbose,
    );

    output.blank();
    output.info('done.');
    return 0;
  }
}

/// `winbridge recipe list` — bundled and user recipes, with where each came
/// from.
class RecipeListCommand extends WinBridgeCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List bundled and user recipes.';

  @override
  Future<int> run() async {
    final output = context.output;
    final bundledDir =
        RecipeLoader.locateBundled(environment: context.config.environment);
    final userDir = RecipeLoader.locateUser(context.config);
    final loaded =
        RecipeLoader(bundledDirectory: bundledDir, userDirectory: userDir)
            .loadAll();
    _reportLoadErrors(output, loaded.errors);

    output.info('bundled recipes: ${bundledDir ?? '(none found)'}');
    output.info('user recipes:    ${userDir ?? '(no data directory)'}');
    output.blank();

    if (loaded.recipes.isEmpty) {
      output.info('no recipes loaded.');
      return 0;
    }

    output.info('ID                              SOURCE   MATCH');
    for (final recipe in loaded.recipes) {
      output.info('${recipe.id.padRight(32)}'
          '${recipe.sourceKind.label.padRight(9)}'
          '${recipe.match.kind.label}');
    }
    return 0;
  }
}
