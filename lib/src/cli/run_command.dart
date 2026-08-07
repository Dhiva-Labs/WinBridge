import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../run/prefix.dart';
import '../run/wine_launcher.dart';
import '../run/wine_runtime.dart';
import 'command.dart';

/// `winbridge run <app.exe> [-- args]` — run a Windows program on Linux.
///
/// The whole point is that nothing about Wine is the user's problem: the
/// runtime installs itself on first use, each app gets its own prefix, and the
/// app's exit code comes back as this command's own.
class RunCommand extends WinBridgeCommand {
  RunCommand() {
    argParser
      ..addOption(
        'prefix',
        valueHelp: 'name',
        help: 'Which app prefix to use.\n'
            "Defaults to the executable's file name without .exe.",
      )
      ..addFlag(
        'list-prefixes',
        negatable: false,
        help: 'List the app prefixes that exist, then exit.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a Windows executable on Linux.';

  @override
  String get invocation => 'winbridge run <app.exe> [-- arguments for the app]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final output = context.output;
    final prefixes = PrefixManager(context.config);

    if (results.flag('list-prefixes')) {
      return _listPrefixes(prefixes);
    }

    final positional = results.rest;
    if (positional.isEmpty) {
      throw const UsageFailure(
        'expected the path to a Windows executable',
        details: 'example: winbridge run build/winbridge/windows-x64/app.exe',
      );
    }

    final executable = p.normalize(p.absolute(positional.first));
    // Everything after the executable — in practice everything past `--` — is
    // the app's own argv, passed through untouched.
    final appArguments = positional.skip(1).toList();

    WineLauncher.checkExecutable(executable);

    final requestedPrefix = results.option('prefix');
    final prefix = requestedPrefix == null
        ? prefixes.forExecutable(executable)
        : prefixes.byName(requestedPrefix, flag: '--prefix');

    final runtime = WineRuntime(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    );
    final wine = await runtime.resolveOrInstall();

    output.detail('wine    ${wine.binary} (${wine.source.label})');
    output.detail('prefix  ${prefix.path}');
    if (!prefix.exists) {
      output.info('Creating a new prefix for ${prefix.name} '
          '(first run takes a moment)');
    }

    final code = await WineLauncher(
      runner: context.processes,
      output: output,
    ).launch(LaunchRequest(
      executable: executable,
      wine: wine,
      prefix: prefix,
      arguments: appArguments,
      verbose: output.verbose,
    ));

    output.detail('app exited with $code');
    return code;
  }

  int _listPrefixes(PrefixManager prefixes) {
    final output = context.output;
    final all = prefixes.list();
    if (all.isEmpty) {
      output.info('no app prefixes yet — `winbridge run <app.exe>` makes one.');
      return 0;
    }
    output.info('NAME                 PATH');
    for (final prefix in all) {
      output.info('${prefix.name.padRight(20)} ${prefix.path}');
    }
    output.blank();
    output.info('Reset an app by deleting its directory.');
    return 0;
  }
}

