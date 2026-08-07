import 'package:winbridge/src/cli/command.dart';
import 'package:winbridge/winbridge.dart';

import 'remote_app.dart';
import 'vm_config.dart';

/// `winbridge vm app <remote-exe-path>` — run a Windows program already
/// installed on the M2 VM as a seamless window on this desktop, via FreeRDP's
/// RemoteApp mode. For the apps Wine cannot run at all: this is not Wine —
/// the program executes for real, on real Windows inside the VM, and only its
/// window (and clipboard, and optionally audio) crosses back to Linux.
class VmAppCommand extends WinBridgeCommand {
  VmAppCommand() {
    argParser.addFlag(
      'sound',
      negatable: false,
      help: "Redirect the remote app's audio to this machine.",
    );
  }

  @override
  String get name => 'app';

  @override
  String get description =>
      'Run a Windows program from the VM as a seamless window (FreeRDP).';

  @override
  String get invocation => 'winbridge vm app <remote-exe-path>';

  @override
  Future<int> run() async {
    final output = context.output;
    final positional = argResults!.rest;
    if (positional.length != 1) {
      throw const UsageFailure(
        'expected exactly one remote executable path',
        details: r'example: winbridge vm app "C:/apps/App/app.exe"',
      );
    }
    final remotePath = positional.single;
    if (!isValidRemoteExecutablePath(remotePath)) {
      throw UsageFailure(
        'invalid remote executable path: "$remotePath"',
        details: 'expected a Windows path matching '
            '${VmConfig.windowsPathCharsetDescription} and no ".." — the '
            "same rule vm.json's remoteWorkspace follows. Paths containing "
            'spaces (e.g. under "Program Files") are not representable yet — '
            'see docs/remoteapp.md.',
      );
    }

    if (context.config.environment[rdpAskPasswordVariable] != null) {
      throw UsageFailure(
        'interactive RDP password prompts are not supported yet',
        details: '$rdpAskPasswordVariable is reserved for that feature; '
            'WinBridge has no way to feed a typed password to the FreeRDP '
            'client today — see docs/remoteapp.md. Use a passwordless or '
            'cached-credential VM account instead, or run the FreeRDP '
            'client directly.',
      );
    }

    final config =
        VmConfig.load(environment: context.config.environment, output: output);

    final ResolvedTool client;
    try {
      client = context.tools.requireAny(
        remoteAppClientCandidates,
        reason: 'launches a Windows app from the VM as a seamless window',
      );
    } on ToolNotFound catch (error) {
      throw RemoteAppToolNotFound(error);
    }

    final request = RemoteAppRequest(
      config: config,
      remoteExecutablePath: remotePath,
      sound: argResults!.flag('sound'),
    );
    final arguments = remoteAppArguments(request);

    output.info('client    ${client.path}');
    output.info('vm        ${config.user}@${config.host}:${config.port}');
    output.info('app       $remotePath');
    output.detail('\$ ${client.path} ${arguments.join(' ')}');

    final result = await context.processes.run(
      client.path,
      arguments,
      streamOutput: true,
      captureOutput: false,
    );
    return result.exitCode;
  }
}
