@Timeout(Duration(minutes: 10))
library;

import 'package:test/test.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/src/run/winetricks.dart';
import 'package:winbridge/winbridge.dart';

/// Really downloads the pinned winetricks and really runs it against a real
/// prefix, using a verb that only reads state.
///
/// Deliberately metadata-only: verbs that install redistributables pull tens
/// of megabytes from third-party servers and take minutes, which does not
/// belong in a suite people run on every change. What this covers is the part
/// WinBridge owns — that the pinned script downloads, verifies, finds our Wine,
/// and talks to the prefix we pointed it at.
void main() {
  final config = WinBridgeConfig();
  final resolver = ToolResolver(config: config);
  final quiet = Output(out: StringBuffer(), err: StringBuffer());

  final wine = WineRuntime(
    config: config,
    tools: resolver,
    runner: ProcessRunner(),
    output: quiet,
  ).resolve();
  final bash = resolver.resolve('bash');

  test(
    'runs a read-only verb against a real prefix with our own Wine',
    () async {
      final prefix = PrefixManager(config)
          .byName('winbridge_tricks_test', flag: '--prefix');
      final captured = StringBuffer();

      final code = await Winetricks(
        config: config,
        tools: resolver,
        runner: ProcessRunner(output: Output(out: captured, err: captured)),
        output: Output(out: captured, err: captured),
      ).run(
        prefix: prefix,
        wine: wine!,
        verbs: [WinetricksVerb.parse('list-installed')],
      );

      expect(code, 0, reason: captured.toString());

      final output = captured.toString();
      // winetricks prints the version and the Wine it found; both are things
      // WinBridge is responsible for having wired up correctly.
      expect(output, contains(pinnedWinetricks.version));
      expect(
        output,
        contains('wine-'),
        reason: 'winetricks should report the Wine build it picked up',
      );
    },
    skip: wine == null
        ? 'no Wine runtime installed (run `winbridge run` once first)'
        : bash == null
            ? 'no bash to run winetricks with'
            : false,
  );
}
