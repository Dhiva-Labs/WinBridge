import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/src/cli/command.dart';
import 'package:winbridge/winbridge.dart';

import 'desktop_entry.dart';
import 'desktop_store.dart';

/// `winbridge desktop` — manage `.desktop` launcher entries for apps run
/// through `winbridge run`. Has no action of its own; `add`, `list` and
/// `remove` are its subcommands.
class DesktopCommand extends WinBridgeCommand {
  DesktopCommand() {
    addSubcommand(DesktopAddCommand());
    addSubcommand(DesktopListCommand());
    addSubcommand(DesktopRemoveCommand());
  }

  @override
  String get name => 'desktop';

  @override
  String get description =>
      'Add or remove desktop launcher entries for Windows apps.';
}

/// `winbridge desktop add <app.exe> [--name "Display Name"] [--prefix <name>]`
class DesktopAddCommand extends WinBridgeCommand {
  DesktopAddCommand() {
    argParser
      ..addOption(
        'name',
        valueHelp: 'text',
        help: 'Display name shown in the launcher.\n'
            "Defaults to the executable's file name without .exe.",
      )
      ..addOption(
        'prefix',
        valueHelp: 'name',
        help: 'Which app prefix `winbridge run` should use.\n'
            "Defaults to the executable's file name without .exe.",
      );
  }

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add a desktop launcher entry for a Windows executable.';

  @override
  String get invocation =>
      'winbridge desktop add <app.exe> [--name "Display Name"] '
      '[--prefix <name>]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final output = context.output;

    final positional = results.rest;
    if (positional.length != 1) {
      throw const UsageFailure(
        'expected the path to a Windows executable',
        details: 'example: winbridge desktop add '
            'build/winbridge/windows-x64/app.exe',
      );
    }

    final executable = p.normalize(p.absolute(positional.first));
    _checkExecutable(executable);

    final stem = p.basenameWithoutExtension(executable);
    final entry = DesktopEntry(
      slug: stem,
      name: results.option('name') ?? stem,
      prefix: results.option('prefix') ?? stem,
      executablePath: executable,
    );

    final store = DesktopEntryStore(context.config);
    final path = store.write(entry);
    output.info('Added ${entry.name} -> $path');
    output.detail('exec: winbridge run --prefix ${entry.prefix} $executable');

    await refreshDesktopDatabase(
      tools: context.tools,
      runner: context.processes,
      directory: store.directory,
      output: output,
    );
    return 0;
  }

  /// Only what a launcher entry needs to know before it is written: the file
  /// exists and starts with the DOS/PE `MZ` signature. The fuller PE32+
  /// header check `winbridge run` applies at launch time (`lib/src/pe/`) is
  /// deliberately not reused here — this only ever needs to catch "that is
  /// not even a Windows binary" before a launcher entry gets written for it,
  /// and Wine gives the real answer for anything past that when the entry is
  /// actually opened.
  void _checkExecutable(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageFailure('no such file: $path');
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      throw UsageFailure('not a file: $path');
    }
    final List<int> head;
    try {
      final handle = file.openSync();
      try {
        head = handle.readSync(2);
      } finally {
        handle.closeSync();
      }
    } on FileSystemException catch (error) {
      throw UsageFailure('cannot read $path', details: error.osError?.message);
    }
    if (head.length < 2 || head[0] != 0x4d || head[1] != 0x5a) {
      throw UsageFailure(
        'not a Windows executable: ${p.basename(path)}',
        details: 'expected the MZ header at the start of the file',
      );
    }
  }
}

/// `winbridge desktop list`
class DesktopListCommand extends WinBridgeCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List the desktop launcher entries winbridge owns.';

  @override
  Future<int> run() async {
    final output = context.output;
    final entries = DesktopEntryStore(context.config).list();
    if (entries.isEmpty) {
      output.info(
        'no desktop entries yet — `winbridge desktop add <app.exe>` makes '
        'one.',
      );
      return 0;
    }

    output.info('NAME                 TARGET');
    for (final entry in entries) {
      output.info('${entry.name.padRight(20)} ${entry.target}');
    }
    return 0;
  }
}

/// `winbridge desktop remove <slug-or-name>`
class DesktopRemoveCommand extends WinBridgeCommand {
  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a desktop launcher entry winbridge owns.';

  @override
  String get invocation => 'winbridge desktop remove <slug-or-name>';

  @override
  Future<int> run() async {
    final positional = argResults!.rest;
    if (positional.length != 1) {
      throw const UsageFailure(
        'expected exactly one desktop entry name',
        details: 'see `winbridge desktop list`',
      );
    }

    final output = context.output;
    final store = DesktopEntryStore(context.config);
    store.remove(positional.single);
    output.info('Removed ${positional.single}');

    await refreshDesktopDatabase(
      tools: context.tools,
      runner: context.processes,
      directory: store.directory,
      output: output,
    );
    return 0;
  }
}
