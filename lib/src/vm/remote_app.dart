import 'package:winbridge/winbridge.dart';

import 'vm_config.dart';

/// FreeRDP client binaries to try, in order. Real installs vary by distro and
/// desktop: `xfreerdp`/`xfreerdp3` is the X11 client most packages ship,
/// `wlfreerdp` is the native Wayland client, and `sdl-freerdp` is FreeRDP's
/// newer SDL-based UI. The first one present on [ToolResolver]'s search path
/// is used; nothing here prefers one over another for any reason but
/// availability.
const remoteAppClientCandidates = [
  'xfreerdp',
  'xfreerdp3',
  'wlfreerdp',
  'sdl-freerdp',
];

/// What to tell someone who has none of [remoteAppClientCandidates] installed.
const remoteAppPackageAdvice =
    'install freerdp3-x11 (or freerdp2-x11 on an older distro) — see '
    'docs/remoteapp.md';

/// Reserved for a future interactive password prompt, once `ProcessRunner`
/// can wire a child's stdin to the terminal it did not spawn from. Setting
/// this today gets a clear refusal instead of a silent hang — see
/// docs/remoteapp.md for why WinBridge cannot safely prompt yet.
const rdpAskPasswordVariable = 'WINBRIDGE_RDP_ASK';

/// Whether [value] is safe to embed as the RemoteApp target: the same
/// charset [VmConfig] validates `remoteWorkspace` against, since this is the
/// same kind of value — a Windows path that reaches a remote command line —
/// just supplied on WinBridge's own command line instead of a config file.
bool isValidRemoteExecutablePath(String value) =>
    VmConfig.isValidWindowsPath(value);

/// Everything one `vm app` launch needs, already validated.
class RemoteAppRequest {
  const RemoteAppRequest({
    required this.config,
    required this.remoteExecutablePath,
    this.sound = false,
  });

  final VmConfig config;

  /// A Windows path on the VM, e.g. `C:/apps/App/app.exe`. Validated by
  /// [isValidRemoteExecutablePath] before a [RemoteAppRequest] is built —
  /// this class does not re-check it.
  final String remoteExecutablePath;

  /// Whether to redirect the remote app's audio to this machine.
  final bool sound;
}

/// Builds the argv for launching [request] as a seamless RemoteApp window.
///
/// FreeRDP3 syntax: `/app:program:"<path>"` names the remote executable to
/// run instead of a full desktop — the RemoteApp fallback never opens a
/// desktop session, only the one program's window. `+clipboard` redirects the
/// clipboard both ways, which is what makes a RemoteApp window feel like a
/// local one rather than a remote desktop in a box.
///
/// `/cert:tofu` trusts an unseen certificate once and remembers it — the RDP
/// analogue of SSH's `--accept-new`, and a deliberate choice over strict
/// checking or `/cert:ignore`. See docs/remoteapp.md for the full argument:
/// in short, the M2 VM's RDP certificate is self-signed per VM and changes on
/// every rebuild of a disposable, `127.0.0.1`-only guest, so strict checking
/// would demand a manual re-trust after every VM recreation for no real gain,
/// while `/cert:ignore` throws the check away entirely. `tofu` is the middle
/// ground: an unseen cert is trusted once, but a cert that changed *without*
/// a deliberate VM rebuild is still flagged.
///
/// No password ever appears here — see [rdpAskPasswordVariable] and
/// docs/remoteapp.md.
List<String> remoteAppArguments(RemoteAppRequest request) {
  final config = request.config;
  return [
    '/v:${config.host}:${config.port}',
    '/u:${config.user}',
    '/app:program:"${request.remoteExecutablePath}"',
    '/cert:tofu',
    '+clipboard',
    if (request.sound) '/sound',
  ];
}

/// A richer, actionable error for when none of [remoteAppClientCandidates]
/// resolved: names the package to install and where to read more, on top of
/// [ToolNotFound]'s own list of names tried and directories searched.
class RemoteAppToolNotFound extends WinBridgeException {
  RemoteAppToolNotFound(ToolNotFound cause)
      : super(
          'no FreeRDP client found (tried '
          '${cause.names.map((n) => '`$n`').join(', ')})',
          details: '$remoteAppPackageAdvice\n\n${cause.details}',
        );

  @override
  int get exitCode => 1;
}
