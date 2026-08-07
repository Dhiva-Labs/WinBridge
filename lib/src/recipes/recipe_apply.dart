import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/src/run/dxvk.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/run/winetricks.dart';
import 'package:winbridge/winbridge.dart';

import 'recipe.dart';

/// Records which recipe last set dll overrides for a prefix, so a later
/// `winbridge run` in that prefix can compose them the same way `--dxvk` is
/// sticky per prefix (`.winbridge-dxvk`, see `lib/src/run/dxvk.dart`). This is
/// data only, mirroring the DXVK marker's own shape — nothing here executes.
///
/// NOT wired into `winbridge run` yet: `lib/src/cli/run_command.dart` is
/// outside this module's boundary. [recipeDllOverrides] is the one call the
/// wiring needs — see docs/recipes.md and the M5 report for the exact line.
const recipeMarkerFileName = '.winbridge-recipe';

/// The dll overrides recorded against one prefix by [RecipeApplier.apply].
class AppliedRecipeMarker {
  const AppliedRecipeMarker({required this.recipeId, required this.dllOverrides});

  final String recipeId;
  final Map<String, String> dllOverrides;

  Map<String, dynamic> toJson() => {
        'recipeId': recipeId,
        'dllOverrides': dllOverrides,
      };

  /// The marker recorded against [prefix], or null when there is none, it is
  /// unreadable, or it does not have the shape this version writes. A
  /// corrupt or foreign marker is ignored rather than trusted — it is never
  /// spliced into anything without going back through the same charset
  /// [Recipe.fromJson] itself enforces on load, so nothing here executes what
  /// it reads either.
  static AppliedRecipeMarker? read(AppPrefix prefix) {
    final file = File(p.join(prefix.path, recipeMarkerFileName));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) return null;
      final recipeId = decoded['recipeId'];
      final overrides = decoded['dllOverrides'];
      if (recipeId is! String || overrides is! Map) return null;
      final dllOverrides = <String, String>{};
      for (final entry in overrides.entries) {
        final dll = '${entry.key}';
        final value = entry.value;
        if (!RecipeApply.dllNamePattern.hasMatch(dll)) continue;
        if (value is! String || !RecipeApply.validOverrideValues.contains(value)) {
          continue;
        }
        dllOverrides[dll] = value;
      }
      return AppliedRecipeMarker(recipeId: recipeId, dllOverrides: dllOverrides);
    } on FormatException {
      return null;
    }
  }

  void write(AppPrefix prefix) {
    File(p.join(prefix.path, recipeMarkerFileName))
        .writeAsStringSync('${jsonEncode(toJson())}\n');
  }
}

/// The `WINEDLLOVERRIDES` fragment for whatever recipe is recorded against
/// [prefix], or [existing] unchanged when nothing is recorded.
///
/// Composed exactly the way `dxvkDllOverrides` composes DXVK's own overrides:
/// our entries come first, [existing] is appended after, so an explicit
/// `WINEDLLOVERRIDES` — the user's own, or DXVK's — still wins; Wine takes the
/// last entry for a given dll. A future `run_command.dart` wiring chains this
/// the same way `--dxvk` chains `dxvkDllOverrides`.
String? recipeDllOverrides(AppPrefix prefix, {String? existing}) {
  final marker = AppliedRecipeMarker.read(prefix);
  if (marker == null || marker.dllOverrides.isEmpty) return existing;
  final ours =
      marker.dllOverrides.entries.map((e) => '${e.key}=${e.value}').join(';');
  final theirs = existing?.trim();
  return (theirs == null || theirs.isEmpty) ? ours : '$ours;$theirs';
}

/// Applies one [Recipe] to one prefix: winetricks verbs, then DXVK, then
/// recording dll overrides for later runs to pick up. Every step goes through
/// the run module's own public classes — `Winetricks`, `DxvkInstaller`,
/// `VulkanCheck` — never around them, so a recipe-driven install behaves
/// exactly like the equivalent `winbridge prefix tricks` / `run --dxvk` would.
///
/// Stops at the first failing step and reports it; nothing after a failed
/// step runs, and nothing is retried.
class RecipeApplier {
  RecipeApplier({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
    VulkanCheck Function(ToolResolver)? vulkanCheck,
  }) : _vulkanCheck = vulkanCheck ?? VulkanCheck.detect;

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;

  /// Overridable only for tests: [VulkanCheck.detect] reads fixed filesystem
  /// paths with no fake seam of its own, so a test that needs a deterministic
  /// answer regardless of the machine it runs on supplies one here instead.
  final VulkanCheck Function(ToolResolver) _vulkanCheck;

  Future<void> apply({
    required Recipe recipe,
    required AppPrefix prefix,
    required ResolvedWine wine,
    bool verbose = false,
  }) async {
    Directory(prefix.path).createSync(recursive: true);

    if (recipe.apply.tricks.isNotEmpty) {
      final verbs = recipe.apply.tricks.map((v) => v.value).join(' ');
      output.info('step: winetricks $verbs');
      final code = await Winetricks(
        config: config,
        tools: tools,
        runner: runner,
        output: output,
      ).run(
        prefix: prefix,
        wine: wine,
        verbs: recipe.apply.tricks,
        verbose: verbose,
      );
      if (code != 0) {
        throw BuildFailure(
          'winetricks exited $code applying recipe "${recipe.id}"',
          details: 'verbs: $verbs',
        );
      }
    }

    if (recipe.apply.dxvk) {
      output.info('step: dxvk ${pinnedDxvk.version}');
      final vulkan = _vulkanCheck(tools);
      if (!vulkan.looksAvailable) {
        throw BuildFailure(
          'recipe "${recipe.id}" calls for DXVK, but no Vulkan loader was '
          'found on this machine',
          details: VulkanCheck.missingAdvice,
        );
      }
      if (DxvkInstaller.installedVersion(prefix) != pinnedDxvk.version) {
        await DxvkInstaller(
          config: config,
          tools: tools,
          runner: runner,
          output: output,
        ).installInto(prefix);
      }
    }

    if (recipe.apply.dllOverrides.isNotEmpty) {
      final overrides = recipe.apply.dllOverrides.entries
          .map((e) => '${e.key}=${e.value}')
          .join(' ');
      output.info('step: dll overrides $overrides (recorded for later runs)');
      AppliedRecipeMarker(
        recipeId: recipe.id,
        dllOverrides: recipe.apply.dllOverrides,
      ).write(prefix);
    }
  }
}
