import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../pe/pe_header.dart';
import '../recipes/recipe_apply.dart' show recipeDllOverrides;
import '../run/dxvk.dart';
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
        'dxvk',
        help: 'Render Direct3D through Vulkan instead of Wine\'s own\n'
            'translation, which is markedly faster for 3D apps.\n'
            'Sets the default for this prefix: --dxvk turns it on and\n'
            'leaves it on, --no-dxvk turns it back off.',
      )
      ..addFlag(
        'list-prefixes',
        negatable: false,
        hide: true,
        help: 'Deprecated: use `winbridge prefix list`.',
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
      output.warn('`run --list-prefixes` is deprecated; '
          'use `winbridge prefix list`.');
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

    final machine = WineLauncher.checkExecutable(executable);
    output.detail('image   ${describeMachine(machine)}');

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

    final useDxvk = await _settleDxvk(results, prefix);

    final envOverrides = context.config.environment['WINEDLLOVERRIDES'];
    final code = await WineLauncher(
      runner: context.processes,
      output: output,
    ).launch(LaunchRequest(
      executable: executable,
      wine: wine,
      prefix: prefix,
      arguments: appArguments,
      verbose: output.verbose,
      dllOverrides: recipeDllOverrides(
        prefix,
        existing:
            useDxvk ? dxvkDllOverrides(existing: envOverrides) : envOverrides,
      ),
    ));

    output.detail('app exited with $code');
    return code;
  }

  /// Works out whether this run uses DXVK, installing or removing it when the
  /// flag says so.
  ///
  /// With no flag the prefix decides: a prefix that was set up with `--dxvk`
  /// keeps using it, which is the point of making it sticky — you say it once
  /// per app, not once per launch.
  Future<bool> _settleDxvk(ArgResults results, AppPrefix prefix) async {
    final output = context.output;
    if (!results.wasParsed('dxvk')) return DxvkInstaller.isEnabledFor(prefix);

    if (!results.flag('dxvk')) {
      if (DxvkInstaller.isEnabledFor(prefix)) {
        DxvkInstaller.disableFor(prefix);
        output.info('DXVK turned off for ${prefix.name}.');
      }
      return false;
    }

    final vulkan = VulkanCheck.detect(
      context.tools,
      arch: context.config.hostArch,
    );
    if (!vulkan.looksAvailable) {
      throw const BuildFailure(
        'no Vulkan loader found, so DXVK cannot run here',
        details: VulkanCheck.missingAdvice,
      );
    }

    if (DxvkInstaller.installedVersion(prefix) != pinnedDxvk.version) {
      output.info('Installing DXVK ${pinnedDxvk.version} into ${prefix.name}');
      await DxvkInstaller(
        config: context.config,
        tools: context.tools,
        runner: context.processes,
        output: output,
      ).installInto(prefix);
    }
    return true;
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
    output.info('Reset an app with `winbridge prefix delete <name>`.');
    return 0;
  }
}
