import 'package:winbridge/src/cli/command.dart';
import 'package:winbridge/winbridge.dart';

import 'remote_command.dart';
import 'usb.dart';
import 'vm_config.dart';
import 'vm_transport.dart';

const _acceptNewHelp = 'Trust a VM host key seen for the first time. Never '
    'relaxes checking for a host key that changed — only ssh itself, run '
    'directly, can do that.';

/// `winbridge vm` — connectivity and setup checks for the build VM. Has no
/// action of its own; `status`, `doctor` and `usb` are its subcommands.
class VmCommand extends WinBridgeCommand {
  VmCommand() {
    addSubcommand(VmStatusCommand());
    addSubcommand(VmDoctorCommand());
    addSubcommand(VmUsbCommand());
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

/// `winbridge vm usb` — enumerate host USB devices and print VM passthrough
/// configuration for one of them. Has no action of its own; both `list` and
/// `passthrough` only ever read the host or print text — nothing here writes
/// to a compose file or a libvirt domain on the user's behalf.
class VmUsbCommand extends WinBridgeCommand {
  VmUsbCommand() {
    addSubcommand(VmUsbListCommand());
    addSubcommand(VmUsbPassthroughCommand());
  }

  @override
  String get name => 'usb';

  @override
  String get description => 'List host USB devices and configure VM passthrough.';
}

/// `winbridge vm usb list` — what `lsusb` sees, trimmed to devices that are
/// actual passthrough candidates by default.
class VmUsbListCommand extends WinBridgeCommand {
  VmUsbListCommand() {
    argParser.addFlag(
      'all',
      negatable: false,
      help: 'Include root hubs and hubs, hidden by default.',
    );
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List USB devices on this machine.';

  @override
  Future<int> run() async {
    final output = context.output;
    final lsusb = context.tools.requirePath(
      'lsusb',
      reason: 'lists USB devices attached to this machine',
    );
    final result = await context.processes.run(lsusb, const []);
    if (!result.ok) {
      throw ProcessFailure(
        result.commandLine,
        result.exitCode,
        output: result.diagnostics,
        what: 'lsusb',
      );
    }

    final showAll = argResults!.flag('all');
    final devices = [
      for (final device in parseLsusb(result.stdout))
        if (showAll || !device.isHubLike) device,
    ];

    if (devices.isEmpty) {
      output.info(showAll
          ? 'no USB devices found.'
          : 'no non-hub USB devices found (use --all to include hubs).');
      return 0;
    }

    output.info('VENDOR:PRODUCT  BUS  DEV  NAME');
    for (final device in devices) {
      output.info(
        '${device.id.padRight(14)}  ${device.bus}  ${device.device}  '
        '${device.name}',
      );
    }
    return 0;
  }
}

/// `winbridge vm usb passthrough <vendor:product>` — print, never apply, the
/// dockur/windows compose fragment and the libvirt equivalent for handing one
/// USB device to the VM.
class VmUsbPassthroughCommand extends WinBridgeCommand {
  @override
  String get name => 'passthrough';

  @override
  String get description =>
      'Print VM configuration to pass a USB device through.';

  @override
  String get invocation => 'winbridge vm usb passthrough <vendor:product>';

  @override
  Future<int> run() async {
    final positional = argResults!.rest;
    if (positional.length != 1) {
      throw UsageFailure(
        'expected exactly one argument: vendor:product',
        details: 'example: winbridge vm usb passthrough 1462:7c95\n'
            'run `winbridge vm usb list` to find one',
      );
    }

    final id = UsbId.parse(positional.single);
    final instructions = usbPassthroughInstructions(id);
    final output = context.output;

    output.info('For dockur/windows:');
    output.blank();
    output.info(instructions.composeSnippet);
    output.blank();
    output.info('For libvirt (virt-install / virsh), save this as a file:');
    output.blank();
    output.info(instructions.libvirtXml);
    output.blank();
    output.info('Then attach it live, without editing the domain XML:');
    output.blank();
    output.info('  ${instructions.virshCommand}');
    output.blank();
    output.info(
      'Then install the vendor driver inside the VM, as on any Windows '
      'machine.',
    );
    return 0;
  }
}

String _firstLine(String text) => text.trim().split('\n').first;
