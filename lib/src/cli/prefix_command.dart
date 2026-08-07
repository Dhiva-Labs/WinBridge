import 'dart:io';

import '../core/errors.dart';
import '../run/dxvk.dart';
import '../run/prefix.dart';
import '../run/wine_runtime.dart';
import '../run/winetricks.dart';
import 'command.dart';

/// `winbridge prefix` — manage the per-app Windows worlds `run` creates.
class PrefixCommand extends WinBridgeCommand {
  PrefixCommand() {
    addSubcommand(PrefixListCommand());
    addSubcommand(PrefixDeleteCommand());
    addSubcommand(PrefixTricksCommand());
  }

  @override
  String get name => 'prefix';

  @override
  String get description => 'Inspect and manage per-app Wine prefixes.';
}

class PrefixListCommand extends WinBridgeCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List the app prefixes that exist.';

  @override
  Future<int> run() async {
    final output = context.output;
    final prefixes = PrefixManager(context.config).list();
    if (prefixes.isEmpty) {
      output.info('no app prefixes yet — `winbridge run <app.exe>` makes one.');
      return 0;
    }

    output.info('NAME                 DXVK     PATH');
    for (final prefix in prefixes) {
      final dxvk = DxvkInstaller.installedVersion(prefix) ?? '-';
      output.info('${prefix.name.padRight(20)} ${dxvk.padRight(8)} '
          '${prefix.path}');
    }
    output.blank();
    output.info('Reset an app with `winbridge prefix delete <name>`.');
    return 0;
  }
}

class PrefixDeleteCommand extends WinBridgeCommand {
  @override
  String get name => 'delete';

  @override
  String get description => 'Delete an app prefix and everything in it.';

  @override
  String get invocation => 'winbridge prefix delete <name>';

  @override
  Future<int> run() async {
    final output = context.output;
    final positional = argResults!.rest;
    if (positional.length != 1) {
      throw const UsageFailure(
        'expected exactly one prefix name',
        details: 'see `winbridge prefix list`',
      );
    }

    final prefix =
        PrefixManager(context.config).byName(positional.single, flag: 'name');
    if (!prefix.exists) {
      throw UsageFailure(
        'no prefix named "${prefix.name}"',
        details: 'see `winbridge prefix list`',
      );
    }

    Directory(prefix.path).deleteSync(recursive: true);
    output.info('Deleted ${prefix.path}');
    output.info('The next run of that app builds a fresh prefix.');
    return 0;
  }
}

/// `winbridge prefix tricks <name> <verb...>` — install redistributables and
/// tweaks into one prefix through winetricks.
class PrefixTricksCommand extends WinBridgeCommand {
  @override
  String get name => 'tricks';

  @override
  String get description =>
      'Run winetricks against a prefix (fonts, runtimes, tweaks).';

  @override
  String get invocation => 'winbridge prefix tricks <name> <verb> [verb...]';

  @override
  Future<int> run() async {
    final output = context.output;
    final positional = argResults!.rest;
    if (positional.length < 2) {
      throw const UsageFailure(
        'expected a prefix name and at least one winetricks verb',
        details: 'example: winbridge prefix tricks mygame corefonts vcrun2019\n'
            'list what is available: winbridge prefix tricks mygame list',
      );
    }

    final prefix =
        PrefixManager(context.config).byName(positional.first, flag: 'name');
    final verbs = [
      for (final raw in positional.skip(1)) WinetricksVerb.parse(raw),
    ];

    final wine = await WineRuntime(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    ).resolveOrInstall();

    if (!prefix.exists) {
      output.info('Creating a new prefix for ${prefix.name} '
          '(first run takes a moment)');
    }
    Directory(prefix.path).createSync(recursive: true);

    output.detail('prefix  ${prefix.path}');
    output.detail('wine    ${wine.binary}');

    final code = await Winetricks(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    ).run(
      prefix: prefix,
      wine: wine,
      verbs: verbs,
      verbose: output.verbose,
    );

    if (code != 0) {
      throw BuildFailure(
        'winetricks exited $code',
        details: 'verbs: ${verbs.join(' ')}',
      );
    }
    return 0;
  }
}
