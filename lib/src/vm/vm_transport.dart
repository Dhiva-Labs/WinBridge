import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/winbridge.dart';

import 'vm_config.dart';

/// Excluded from every [VmTransport.sendTree] call: build output, Dart's tool
/// cache and VCS metadata never need to leave the host.
const defaultSendExcludes = ['build/', '.dart_tool/', '.git/'];

/// How WinBridge talks to the build VM: run a command, push a source tree,
/// pull one back. [OpenSshTransport] is the real implementation; tests use a
/// fake so the suite never opens a socket.
abstract class VmTransport {
  Future<RunResult> run(List<String> remoteArgs);

  Future<RunResult> sendTree(
    String localDir,
    String remoteDir, {
    List<String> excludes = defaultSendExcludes,
  });

  Future<RunResult> fetchTree(String remoteDir, String localDir);
}

/// `ssh`/`rsync`-backed [VmTransport].
///
/// Every process this spawns goes through the [ProcessRunner] it was given,
/// as an argv list — see `remote_command.dart` for the one place that is
/// allowed to look different, which is the string `-e` hands to `rsync` for
/// its own (non-shell) word-splitting of the `ssh` sub-invocation.
class OpenSshTransport implements VmTransport {
  OpenSshTransport({
    required this.config,
    required this.runner,
    required this.tools,
    this.acceptNewHostKey = false,
  });

  final VmConfig config;
  final ProcessRunner runner;
  final ToolResolver tools;

  /// Relaxes `StrictHostKeyChecking` from `yes` to `accept-new`: an unknown
  /// host is trusted on first connect, but a host whose key *changed* is
  /// still refused. This must never become `no` — that would also accept a
  /// changed key, which is exactly the case strict checking exists to catch.
  final bool acceptNewHostKey;

  String get _destination => '${config.user}@${config.host}';

  List<String> _sshOptions() => [
        '-p', '${config.port}',
        if (config.identityFile case final identity?) ...[
          '-i', identity,
          '-o', 'IdentitiesOnly=yes',
        ],
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=${acceptNewHostKey ? 'accept-new' : 'yes'}',
        '-o', 'ConnectTimeout=10',
      ];

  @override
  Future<RunResult> run(List<String> remoteArgs) async {
    final ssh = tools.requirePath('ssh', reason: 'connects to the build VM');
    return runner.run(ssh, [..._sshOptions(), _destination, ...remoteArgs]);
  }

  @override
  Future<RunResult> sendTree(
    String localDir,
    String remoteDir, {
    List<String> excludes = defaultSendExcludes,
  }) async {
    final rsync = tools.requirePath('rsync', reason: 'syncs sources to the build VM');
    return runner.run(rsync, [
      '-rt',
      '--no-links',
      '--safe-links',
      for (final exclude in excludes) ...['--exclude', exclude],
      '-e', _rsyncShell(),
      _withTrailingSlash(localDir),
      '$_destination:${_withTrailingSlash(remoteDir)}',
    ]);
  }

  @override
  Future<RunResult> fetchTree(String remoteDir, String localDir) async {
    final rsync = tools.requirePath('rsync', reason: 'fetches build output from the VM');
    Directory(localDir).createSync(recursive: true);

    final result = await runner.run(rsync, [
      '-rt',
      '--no-links',
      '--safe-links',
      '-e', _rsyncShell(),
      '$_destination:${_withTrailingSlash(remoteDir)}',
      _withTrailingSlash(localDir),
    ]);
    if (!result.ok) return result;

    // Fetched files are external input. `--no-links` already keeps rsync
    // from transferring a symlink, but a build is only as trustworthy as the
    // VM producing it, so this re-checks from scratch rather than assuming
    // the flags above were enough: any link is rejected outright, and every
    // regular file must resolve strictly inside `localDir`.
    if (Directory(localDir).existsSync()) {
      for (final entity
          in Directory(localDir).listSync(recursive: true, followLinks: false)) {
        if (entity is Link) {
          throw ArtifactFailure(
            'the VM sent a symlink: ${entity.path}',
            details: 'build output must be regular files only',
          );
        }
        if (entity is! File) continue;
        requireInside(
          parent: localDir,
          child: entity.path,
          what: 'fetched file ${p.basename(entity.path)}',
        );
      }
    }
    return result;
  }

  /// The single string `rsync -e` splits on whitespace to build its own `ssh`
  /// invocation. This is `rsync`'s own parsing, not a shell, and every word in
  /// it is either the resolved `ssh` path or one of [_sshOptions]'s already-
  /// validated tokens.
  String _rsyncShell() {
    final ssh = tools.requirePath('ssh', reason: 'transport for rsync');
    return ([ssh, ..._sshOptions()]).join(' ');
  }

  static String _withTrailingSlash(String path) =>
      path.endsWith('/') ? path : '$path/';
}
