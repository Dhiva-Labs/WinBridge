import 'dart:io';

import 'package:path/path.dart' as p;

import '../bootstrap/components.dart';
import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import '../run/asset_cache.dart';
import '../run/prefix.dart';
import '../run/wine_launcher.dart';
import '../run/wine_runtime.dart';
import 'nsis_script.dart';

/// Builds a Windows installer by running the real `makensis.exe` under
/// WinBridge's own Wine runtime.
///
/// There is a Linux-native NSIS, but using the Windows build through our own
/// managed Wine means one pinned NSIS on every machine and no dependency on
/// what a distribution happens to package — and it is the same engine
/// `winbridge run` already installs and verifies, so it costs nothing extra.
class InstallerBuilder {
  InstallerBuilder({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
  }) : _cache = AssetCache(
          config: config,
          tools: tools,
          runner: runner,
          output: output,
        );

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;
  final AssetCache _cache;

  /// The prefix NSIS itself runs in — shared across projects and disposable.
  /// Separate from any app's prefix so building an installer never touches the
  /// world an app runs in.
  static const toolPrefixName = 'winbridge-tools';

  /// Whether the pinned NSIS is already installed.
  bool get isNsisInstalled => _cache.isInstalled(nsisDistribution);

  /// `makensis.exe` inside the installed distribution.
  ///
  /// The zip has a small launcher at the root and the real compiler in `Bin/`;
  /// the launcher is what knows how to find `Include` and `Stubs`, so that is
  /// the one to run.
  String? get makensisPath {
    final directory = _cache.directoryFor(nsisDistribution);
    return directory == null ? null : p.join(directory, 'makensis.exe');
  }

  Future<String> ensureNsis() async {
    await _cache.ensure(nsisDistribution);
    final path = makensisPath!;
    if (!File(path).existsSync()) {
      throw BuildFailure(
        'the NSIS distribution has no makensis.exe',
        details: path,
      );
    }
    return path;
  }

  /// Compiles [scriptPath] into an installer, returning its path.
  Future<String> compile({
    required String scriptPath,
    required String outputFile,
    required ResolvedWine wine,
    bool verbose = false,
  }) async {
    final makensis = await ensureNsis();
    final prefix = PrefixManager(config).byName(toolPrefixName, flag: 'name');
    Directory(prefix.path).createSync(recursive: true);
    Directory(p.dirname(outputFile)).createSync(recursive: true);

    output.detail('makensis $makensis');
    output.detail('script   $scriptPath');

    final result = await runner.run(
      wine.binary,
      // The script is named relatively and run from its own directory. NSIS
      // uses `/` to introduce options, so an absolute Unix path here is parsed
      // as a flag — makensis answers with its usage text and exits non-zero.
      [makensis, '/V2', p.basename(scriptPath)],
      workingDirectory: p.dirname(scriptPath),
      environment: WineLauncher.environmentFor(LaunchRequest(
        executable: makensis,
        wine: wine,
        prefix: prefix,
        verbose: verbose,
      )),
      streamOutput: verbose,
      captureOutput: true,
    );

    if (!result.ok) {
      throw BuildFailure(
        'makensis failed (exit ${result.exitCode})',
        details: result.diagnostics.trim().isEmpty
            ? 'no output from makensis'
            : result.diagnostics,
      );
    }
    if (!File(outputFile).existsSync()) {
      throw BuildFailure(
        'makensis reported success but produced no installer',
        details: 'expected $outputFile\n${result.stdout}',
      );
    }
    return outputFile;
  }

  /// Writes the generated script beside the artifacts, compiles it, and puts
  /// the installer where the caller asked for it.
  ///
  /// NSIS always writes beside the script (see [compile]); moving afterwards is
  /// what makes `--output somewhere/else.exe` work without teaching the script
  /// generator about Windows paths.
  Future<String> buildDefaultInstaller({
    required InstallerSpec spec,
    required String workingDirectory,
    required String destination,
    required ResolvedWine wine,
    bool verbose = false,
  }) async {
    final scriptPath = p.join(workingDirectory, '${spec.appName}.nsi');
    File(scriptPath).writeAsStringSync(generateNsisScript(spec));
    output.detail('generated $scriptPath');

    final produced = await compile(
      scriptPath: scriptPath,
      outputFile: p.join(workingDirectory, spec.outputFile),
      wine: wine,
      verbose: verbose,
    );
    if (p.equals(produced, destination)) return produced;

    Directory(p.dirname(destination)).createSync(recursive: true);
    File(produced).renameSync(destination);
    return destination;
  }
}
