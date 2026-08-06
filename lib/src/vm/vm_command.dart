import 'package:winbridge/src/cli/command.dart';
import 'package:winbridge/winbridge.dart';

import 'remote_command.dart';
import 'vm_config.dart';
import 'vm_transport.dart';

const _acceptNewHelp = 'Trust a VM host key seen for the first time. Never '
    'relaxes checking for a host key that changed — only ssh itself, run '
    'directly, can do that.';

/// `winbridge vm` — connectivity and setup checks for the build VM. Has no
/// action of its own; `status` and `doctor` are its only subcommands.
class VmCommand extends WinBridgeCommand {
  VmCommand() {
    addSubcommand(VmStatusCommand());
    addSubcommand(VmDoctorCommand());
  }

  @override
  String get name => 'vm';

  @override
  String get description => 'Check and inspect the headless Windows build VM.';
}

/// `winbridge vm status` — is the VM up and does it have Flutter.
class VmStatusCommand extends WinBridgeCommand {
  VmStatusCommand() {
    argParser.addFlag('accept-new', negatable: false, help: _acceptNewHelp);
  }

  @override
  String get name => 'status';

  @override
  String get description => 'Check that the build VM is reachable and has Flutter.';

  @override
  Future<int> run() async {
    final output = context.output;
    final config = VmConfig.load(output: output);
    final transport = OpenSshTransport(
      config: config,
      runner: context.processes,
      tools: context.tools,
      acceptNewHostKey: argResults!.flag('accept-new'),
    );
    final commands = RemoteCommands(config);

    output.info('VM         ${config.user}@${config.host}:${config.port}');
    output.info('Workspace  ${config.remoteWorkspace}');
    output.blank();

    final ping = await transport.run(commands.echoProbe());
    if (!ping.ok) {
      output.info('Connectivity  FAILED');
      output.info(ping.diagnostics);
      return 1;
    }
    output.info('Connectivity  ok');

    final version = await transport.run(commands.flutterVersion());
    if (!version.ok) {
      output.info('Flutter       not found on the vm');
      output.detail(version.diagnostics);
      return 1;
    }
    output.info('Flutter       ${_firstLine(version.stdout)}');
    return 0;
  }
}

/// `winbridge vm doctor` — everything `winbridge build` will need from the VM
/// path, checked up front: local ssh/rsync, config validity, connectivity,
/// remote Flutter and rsync.
class VmDoctorCommand extends WinBridgeCommand {
  VmDoctorCommand() {
    argParser.addFlag('accept-new', negatable: false, help: _acceptNewHelp);
  }

  @override
  String get name => 'doctor';

  @override
  String get description => 'Check that the VM build path is ready to use.';

  @override
  Future<int> run() async {
    final output = context.output;
    final tools = context.tools;
    var problems = 0;

    final ssh = tools.resolve('ssh');
    _report(
      output,
      ssh != null,
      'ssh',
      ssh?.path ?? 'connects to the build VM',
    );
    if (ssh == null) problems++;

    final rsync = tools.resolve('rsync');
    _report(
      output,
      rsync != null,
      'rsync',
      rsync?.path ?? 'syncs the project and its output',
    );
    if (rsync == null) problems++;

    output.blank();

    VmConfig? config;
    try {
      final path = VmConfig.resolvePath();
      output.info('Config     $path');
      config = VmConfig.load(output: output);
      output.info('  ok       valid');
    } on VmConfigError catch (error) {
      output.info('  MISSING  ${error.message}');
      if (error.details != null) output.detail('           ${error.details}');
      problems++;
    }

    if (config != null && ssh != null) {
      final transport = OpenSshTransport(
        config: config,
        runner: context.processes,
        tools: tools,
        acceptNewHostKey: argResults!.flag('accept-new'),
      );
      final commands = RemoteCommands(config);

      final ping = await transport.run(commands.echoProbe());
      output.info(ping.ok ? '  ok       connectivity' : '  FAILED   connectivity');
      if (!ping.ok) {
        output.detail('           ${ping.diagnostics}');
        problems++;
      }

      if (ping.ok) {
        final version = await transport.run(commands.flutterVersion());
        output.info(version.ok
            ? '  ok       remote flutter (${_firstLine(version.stdout)})'
            : '  MISSING  remote flutter');
        if (!version.ok) problems++;

        if (rsync != null) {
          final remoteRsync = await transport.run(commands.whereRsync());
          output.info(remoteRsync.ok
              ? '  ok       remote rsync'
              : '  MISSING  remote rsync (installer: see docs/vm-setup.md)');
          if (!remoteRsync.ok) problems++;
        }
      }
    }

    output.blank();
    if (problems > 0) {
      output.info('$problems ${problems == 1 ? 'problem' : 'problems'} found.');
      return 1;
    }
    output.info('the vm build path looks ready.');
    return 0;
  }

  void _report(Output output, bool ok, String label, String detail) {
    final padded = label.padRight(9);
    output.info(ok ? '  ok       $padded$detail' : '  MISSING  $padded$detail');
  }
}

String _firstLine(String text) => text.trim().split('\n').first;
