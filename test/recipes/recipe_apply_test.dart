import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/recipes/recipe.dart';
import 'package:winbridge/src/recipes/recipe_apply.dart';
import 'package:winbridge/src/run/dxvk.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/run/winetricks.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

Recipe recipeWith({
  String id = 'app',
  List<String> tricks = const [],
  Map<String, String> dllOverrides = const {},
  bool dxvk = false,
}) =>
    Recipe(
      id: id,
      match: const RecipeMatch.sha256(
          '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2'),
      apply: RecipeApply(
        tricks: [for (final t in tricks) WinetricksVerb.parse(t)],
        dllOverrides: dllOverrides,
        dxvk: dxvk,
      ),
      notes: null,
      source: null,
      sourcePath: '$id.json',
      sourceKind: RecipeSourceKind.bundled,
    );

void main() {
  late String home;
  late String pathDir;
  late AppPrefix prefix;
  const wine = ResolvedWine(
    binary: '/rt/bin/wine',
    source: WineSource.managed,
    runtimeDirectory: '/rt',
  );

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    writeExecutable(pathDir, 'bash');
    prefix = AppPrefix(name: 'app', path: p.join(tempDir('prefixes'), 'app'));
  });

  WinBridgeConfig config() =>
      WinBridgeConfig(environment: {'HOME': home, 'PATH': pathDir});

  /// A cached, verified winetricks script, so `Winetricks.ensureScript()`
  /// never tries to download anything.
  void cacheWinetricks() {
    final dir = p.join(home, '.cache', 'winbridge', 'runtimes', pinnedWinetricks.name);
    // Content is never read or executed — `Winetricks.run` is exercised
    // against a `RecordingProcessRunner` below, so only the script's path
    // needs to exist for `AssetCache.isInstalled` to consider it cached.
    writeFile(p.join(dir, 'winetricks'), 'stand-in winetricks script\n');
    writeFile(p.join(dir, '.winbridge-verified'),
        '${pinnedWinetricks.name}\n${pinnedWinetricks.sha256}\n');
  }

  /// A cached, verified DXVK payload, so `DxvkInstaller.installInto` only
  /// ever copies local files.
  void cacheDxvk() {
    final dir = p.join(home, '.cache', 'winbridge', 'runtimes', pinnedDxvk.name);
    for (final arch in ['x64', 'x32']) {
      for (final dll in dxvkDlls) {
        writeFile(p.join(dir, arch, '$dll.dll'), '$arch-$dll-bytes');
      }
    }
    writeFile(p.join(dir, '.winbridge-verified'),
        '${pinnedDxvk.name}\n${pinnedDxvk.sha256}\n');
  }

  void createSystem32() {
    Directory(p.join(prefix.path, 'drive_c', 'windows', 'system32'))
        .createSync(recursive: true);
  }

  RecipeApplier applierWith({
    RecordingProcessRunner? runner,
    VulkanCheck Function(ToolResolver)? vulkanCheck,
  }) {
    final cfg = config();
    return RecipeApplier(
      config: cfg,
      tools: ToolResolver(config: cfg),
      runner: runner ?? RecordingProcessRunner(),
      output: silentOutput(),
      vulkanCheck: vulkanCheck,
    );
  }

  group('winetricks step', () {
    test('runs the recipe\'s verbs, in order, against the prefix', () async {
      cacheWinetricks();
      final runner = RecordingProcessRunner();
      await applierWith(runner: runner).apply(
        recipe: recipeWith(tricks: ['corefonts', 'vcrun2019']),
        prefix: prefix,
        wine: wine,
      );

      expect(runner.calls, hasLength(1));
      final call = runner.calls.single;
      // argv is [script, ...verbs in order] — the script path is whatever
      // the temp cache resolved to, so only the verb tail is asserted here.
      expect(call.arguments.sublist(call.arguments.length - 2),
          ['corefonts', 'vcrun2019']);
      expect(call.environment['WINEPREFIX'], prefix.path);
    });

    test('a failing verb stops everything after it', () async {
      cacheWinetricks();
      cacheDxvk();
      createSystem32();
      final runner = RecordingProcessRunner(onRun: (_) => failResult());

      await expectLater(
        applierWith(runner: runner, vulkanCheck: (_) => _availableVulkan)
            .apply(
          recipe: recipeWith(
              tricks: ['corefonts'], dxvk: true, dllOverrides: {'d3d9': 'n'}),
          prefix: prefix,
          wine: wine,
        ),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('app'))),
      );

      // Nothing past the failed step happened.
      expect(DxvkInstaller.installedVersion(prefix), isNull);
      expect(AppliedRecipeMarker.read(prefix), isNull);
    });

    test('no winetricks call at all when the recipe lists no tricks',
        () async {
      final runner = RecordingProcessRunner();
      await applierWith(runner: runner)
          .apply(recipe: recipeWith(), prefix: prefix, wine: wine);
      expect(runner.calls, isEmpty);
    });
  });

  group('dxvk step', () {
    test('installs DXVK when the recipe calls for it and Vulkan looks '
        'available', () async {
      cacheDxvk();
      createSystem32();
      await applierWith(vulkanCheck: (_) => _availableVulkan).apply(
        recipe: recipeWith(dxvk: true),
        prefix: prefix,
        wine: wine,
      );
      expect(DxvkInstaller.installedVersion(prefix), pinnedDxvk.version);
    });

    test('refuses cleanly, installing nothing, when Vulkan is unavailable',
        () async {
      cacheDxvk();
      createSystem32();
      await expectLater(
        applierWith(vulkanCheck: (_) => _unavailableVulkan).apply(
          recipe: recipeWith(dxvk: true),
          prefix: prefix,
          wine: wine,
        ),
        throwsA(isA<BuildFailure>().having(
            (e) => e.details, 'details', contains('Vulkan'))),
      );
      expect(DxvkInstaller.installedVersion(prefix), isNull);
    });

    test('skipped entirely when the recipe does not ask for it', () async {
      // No dxvk cache seeded at all — if this tried to install DXVK it would
      // fail looking for the payload, so a clean pass proves it never tried.
      await applierWith().apply(
        recipe: recipeWith(),
        prefix: prefix,
        wine: wine,
      );
      expect(DxvkInstaller.installedVersion(prefix), isNull);
    });
  });

  group('dll overrides step', () {
    test('records the overrides map against the prefix', () async {
      await applierWith().apply(
        recipe: recipeWith(id: 'my-app', dllOverrides: {'d3d9': 'n', 'mfc140': 'b'}),
        prefix: prefix,
        wine: wine,
      );
      final marker = AppliedRecipeMarker.read(prefix);
      expect(marker, isNotNull);
      expect(marker!.recipeId, 'my-app');
      expect(marker.dllOverrides, {'d3d9': 'n', 'mfc140': 'b'});
    });

    test('nothing is recorded when the recipe sets no overrides', () async {
      await applierWith()
          .apply(recipe: recipeWith(), prefix: prefix, wine: wine);
      expect(AppliedRecipeMarker.read(prefix), isNull);
    });
  });

  group('an entirely empty apply block', () {
    test('creates the prefix directory and does nothing else', () async {
      final runner = RecordingProcessRunner();
      await applierWith(runner: runner)
          .apply(recipe: recipeWith(), prefix: prefix, wine: wine);
      expect(Directory(prefix.path).existsSync(), isTrue);
      expect(runner.calls, isEmpty);
      expect(AppliedRecipeMarker.read(prefix), isNull);
    });
  });

  group('recipeDllOverrides composition', () {
    // Unlike RecipeApplier.apply, AppliedRecipeMarker.write does not create
    // the prefix directory itself — these tests write the marker directly,
    // so they create it the way the applier already had to have by then.
    setUp(() => Directory(prefix.path).createSync(recursive: true));

    test('null when nothing was ever recorded', () {
      expect(recipeDllOverrides(prefix), isNull);
    });

    test('existing passes through untouched when nothing was recorded', () {
      expect(recipeDllOverrides(prefix, existing: 'd3d11=b'), 'd3d11=b');
    });

    test('our entries come first, existing appended after — so a later, '
        'explicit override still wins', () {
      AppliedRecipeMarker(recipeId: 'x', dllOverrides: {'d3d9': 'n'})
          .write(prefix);
      expect(
        recipeDllOverrides(prefix, existing: 'd3d9=b'),
        'd3d9=n;d3d9=b',
      );
    });

    test('with nothing existing, just our own entries', () {
      AppliedRecipeMarker(recipeId: 'x', dllOverrides: {'d3d9': 'n', 'dxgi': 'b'})
          .write(prefix);
      expect(recipeDllOverrides(prefix), 'd3d9=n;dxgi=b');
    });

    test('a marker with no overrides at all behaves like no marker', () {
      AppliedRecipeMarker(recipeId: 'x', dllOverrides: const {}).write(prefix);
      expect(recipeDllOverrides(prefix, existing: 'd3d9=b'), 'd3d9=b');
    });
  });

  group('AppliedRecipeMarker robustness', () {
    test('a corrupt marker file reads as null rather than throwing', () {
      Directory(prefix.path).createSync(recursive: true);
      writeFile(p.join(prefix.path, recipeMarkerFileName), 'not json at all');
      expect(AppliedRecipeMarker.read(prefix), isNull);
    });

    test('a marker with the wrong shape reads as null', () {
      Directory(prefix.path).createSync(recursive: true);
      writeFile(p.join(prefix.path, recipeMarkerFileName), '[1, 2, 3]');
      expect(AppliedRecipeMarker.read(prefix), isNull);
    });

    test('an override value outside the closed set is dropped, not trusted',
        () {
      Directory(prefix.path).createSync(recursive: true);
      writeFile(
        p.join(prefix.path, recipeMarkerFileName),
        '{"recipeId": "x", "dllOverrides": {"d3d9": "rm -rf /"}}',
      );
      expect(AppliedRecipeMarker.read(prefix)!.dllOverrides, isEmpty);
    });
  });
}

const _availableVulkan =
    VulkanCheck(loaderPath: '/fake/libvulkan.so.1', vulkaninfoPath: null);
const _unavailableVulkan = VulkanCheck(loaderPath: null, vulkaninfoPath: null);
