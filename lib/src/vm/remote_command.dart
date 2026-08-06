import 'vm_config.dart';

/// Builds the command lines sent to the VM over `ssh`.
///
/// INVARIANT: unlike everywhere else WinBridge spawns a process, the far end
/// of this one is a real shell — Windows OpenSSH hands whatever `ssh` sends it
/// to `cmd.exe`. Every token produced here comes either from [VmConfig],
/// which validates its fields against a conservative charset before this
/// class ever sees them, or from a literal constant below. Nothing from the
/// project being built — its name, a file path, `BuildRequest.extraArguments`
/// — may ever reach this file. That is the whole difference between "the VM
/// runs our build" and "a hostile pubspec.yaml runs whatever it wants on the
/// VM".
///
/// Each method returns the remote command as a list of tokens rather than a
/// joined string: `VmTransport.run` passes them to `ssh` as trailing argv
/// elements, and `ssh` itself joins them with a single space before handing
/// the result to the remote shell — so the host-side spawn stays argv-only
/// even though the remote interpretation is not.
class RemoteCommands {
  const RemoteCommands(this.config);

  final VmConfig config;

  /// Fixed checkout directory under [VmConfig.remoteWorkspace]. Deliberately
  /// never the project's own name — that name comes from the project's own
  /// `pubspec.yaml`, which is untrusted input.
  static const _projectDirName = 'project';

  /// Flutter's own layout for a release Windows build. A literal path
  /// segment, not derived from anything the project supplies.
  static const _releaseSubpath = 'build/windows/x64/runner/Release';

  String get remoteProjectDir => '${_dropTrailingSlash(config.remoteWorkspace)}'
      '/$_projectDirName';

  String get remoteReleaseDir => '$remoteProjectDir/$_releaseSubpath';

  String get _flutter =>
      config.flutterPath == null ? 'flutter' : _quote(config.flutterPath!);

  List<String> echoProbe() => const ['echo', 'winbridge-vm-ok'];

  List<String> flutterVersion() => [_flutter, '--version'];

  List<String> pubGet() => [
        ..._cdToProject(),
        '&&',
        _flutter,
        'pub',
        'get',
      ];

  /// `flutter create --platforms=windows .` only fills in a missing platform
  /// folder — it will not overwrite one that is already there — but running
  /// it on every build still costs real time for nothing, so this checks
  /// first and only creates the folder when it is actually absent.
  List<String> ensureWindowsPlatform() => [
        ..._cdToProject(),
        '&&',
        'if',
        'not',
        'exist',
        'windows',
        _flutter,
        'create',
        '--platforms=windows',
        '.',
      ];

  List<String> buildWindowsRelease() => [
        ..._cdToProject(),
        '&&',
        _flutter,
        'build',
        'windows',
        '--release',
      ];

  /// `where` is cmd.exe's `which`; used by `vm doctor` to check that the VM
  /// actually has rsync installed, since a missing remote rsync only ever
  /// shows up as an otherwise-unexplained sync failure.
  List<String> whereRsync() => const ['where', 'rsync'];

  List<String> _cdToProject() => ['cd', '/d', _quote(remoteProjectDir)];

  static String _quote(String value) => '"$value"';

  static String _dropTrailingSlash(String path) =>
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
}
