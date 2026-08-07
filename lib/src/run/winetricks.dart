import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import 'asset_cache.dart';
import 'prefix.dart';
import 'wine_runtime.dart';

/// The exact [winetricks](https://github.com/Winetricks/winetricks) release
/// WinBridge runs, pinned to a tag rather than tracking `master` so an upgrade
/// is a deliberate, reviewable change of these constants.
const pinnedWinetricks = PinnedAsset(
  name: 'winetricks-20260125',
  version: '20260125',
  url: 'https://raw.githubusercontent.com/Winetricks/winetricks/20260125/'
      'src/winetricks',
  sha256: '431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b',
  fileName: 'winetricks',
  executable: true,
);

/// A winetricks verb, validated before it can reach an argument vector.
///
/// Verbs name things winetricks knows how to install (`corefonts`, `vcrun2019`,
/// `dotnet48`). They arrive from the command line, so they get the same
/// treatment as every other externally supplied token in this codebase: one
/// strict pattern, checked up front.
class WinetricksVerb {
  const WinetricksVerb._(this.value);

  final String value;

  /// Lowercase letters, digits, `.`, `_`, `+`, `-` — but never a leading `-`.
  /// The charset is winetricks' own verb naming; the first-character rule is
  /// ours, for the same reason prefix names have it: a token beginning with a
  /// dash is read as an *option* by whatever it is handed to, and these are
  /// handed to winetricks. No real verb starts with one.
  static final RegExp _pattern = RegExp(r'^[a-z0-9._+][a-z0-9._+-]*$');

  static bool isValid(String value) => _pattern.hasMatch(value);

  factory WinetricksVerb.parse(String value) {
    if (!isValid(value)) {
      throw UsageFailure(
        'invalid winetricks verb: "$value"',
        details: 'a verb is lowercase letters, digits, `.`, `_`, `+` or `-` — '
            'for example corefonts, vcrun2019, dotnet48. '
            'Run `winbridge prefix tricks <name> list` to see what exists.',
      );
    }
    return WinetricksVerb._(value);
  }

  @override
  String toString() => value;
}

/// Runs winetricks against one prefix, using WinBridge's own Wine.
class Winetricks {
  Winetricks({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
    this.asset = pinnedWinetricks,
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
  final PinnedAsset asset;
  final AssetCache _cache;

  /// The verified winetricks script, downloading it if this is the first use.
  Future<String> ensureScript() => _cache.ensure(asset);

  /// The environment winetricks runs with.
  ///
  /// `WINE` and `WINESERVER` point it at the exact build WinBridge manages, and
  /// that build's `bin` goes on the front of `PATH` — winetricks shells out to
  /// `wine`, `wineboot` and `wineserver` by name, and without this it would
  /// find a system Wine (or none) instead of the one holding the prefix.
  static Map<String, String> environmentFor({
    required AppPrefix prefix,
    required ResolvedWine wine,
    required String parentPath,
    bool verbose = false,
  }) {
    return {
      'WINEPREFIX': prefix.path,
      'WINE': wine.binary,
      'WINESERVER': wineserverBeside(wine.binary),
      'PATH': parentPath.isEmpty
          ? wine.binDirectory
          : '${wine.binDirectory}:$parentPath',
      if (!verbose) 'WINEDEBUG': '-all',
    };
  }

  /// Runs winetricks with [verbs] against [prefix].
  ///
  /// Output is streamed rather than captured: a verb that downloads and
  /// installs a redistributable can take minutes, and a silent terminal for
  /// that long is indistinguishable from a hang.
  Future<int> run({
    required AppPrefix prefix,
    required ResolvedWine wine,
    required List<WinetricksVerb> verbs,
    bool verbose = false,
  }) async {
    final script = await ensureScript();
    final bash = tools.requirePath('bash', reason: 'runs winetricks');

    final result = await runner.run(
      bash,
      [script, for (final verb in verbs) verb.value],
      workingDirectory: p.dirname(script),
      environment: environmentFor(
        prefix: prefix,
        wine: wine,
        parentPath: config.environment['PATH'] ?? '',
        verbose: verbose,
      ),
      streamOutput: true,
      captureOutput: false,
    );
    return result.exitCode;
  }
}
