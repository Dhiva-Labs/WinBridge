import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/winbridge.dart';

/// The config file is missing, unreadable, malformed, or fails validation.
class VmConfigError extends WinBridgeException {
  const VmConfigError(super.message, {super.details});

  @override
  int get exitCode => 1;
}

/// `mode & 0o044 != 0`: the file grants read access to its group or to
/// everyone. Shared with the test suite, which cannot chmod a real file (see
/// `test/support/fixtures.dart`) and so exercises this against synthetic mode
/// values instead.
bool isGroupOrOtherReadable(int mode) => mode & 0x24 != 0;

/// Connection details for the headless Windows build VM, loaded from
/// `~/.config/winbridge/vm.json`.
///
/// Several of these fields end up spliced into the command line executed on
/// the VM's own shell (see `remote_command.dart` for why that is different
/// from every other process WinBridge spawns). That is what the charsets
/// below are for: [load] never returns a [VmConfig] whose fields have not
/// passed them, so nothing downstream needs to re-check.
class VmConfig {
  const VmConfig({
    required this.host,
    required this.user,
    required this.remoteWorkspace,
    this.port = 22,
    this.identityFile,
    this.flutterPath,
  });

  final String host;
  final int port;
  final String user;

  /// Local path to an SSH private key. Optional: unset relies on `ssh`'s own
  /// default identity discovery or an agent.
  final String? identityFile;

  /// Windows path on the VM, e.g. `C:/winbridge`. Must already exist.
  final String remoteWorkspace;

  /// Path to the `flutter` command on the VM. Unset assumes `flutter` is on
  /// the VM's own `PATH`.
  final String? flutterPath;

  /// Overridden by [configPathVariable] for tests, so they never need a real
  /// `$HOME`.
  static const configPathVariable = 'WINBRIDGE_VM_CONFIG';

  static final RegExp _hostPattern = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _userPattern = RegExp(r'^[A-Za-z0-9._-]+$');
  static final RegExp _windowsPathPattern = RegExp(r'^[A-Za-z0-9:/_.-]+$');
  static final RegExp _whitespace = RegExp(r'\s');

  /// Where [load] looks: [configPathVariable] if set, otherwise
  /// `$XDG_CONFIG_HOME/winbridge/vm.json`, otherwise
  /// `$HOME/.config/winbridge/vm.json`.
  static String resolvePath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final override = env[configPathVariable];
    if (override != null && override.isNotEmpty) {
      return p.normalize(p.absolute(override));
    }
    final xdg = env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty && p.isAbsolute(xdg)) {
      return p.join(p.normalize(xdg), 'winbridge', 'vm.json');
    }
    final home = env['HOME'];
    if (home == null || home.isEmpty || !p.isAbsolute(home)) {
      throw const VmConfigError(
        'cannot locate a VM config: no $configPathVariable, '
        '\$XDG_CONFIG_HOME or \$HOME set',
        details: 'see docs/vm-setup.md',
      );
    }
    return p.join(p.normalize(home), '.config', 'winbridge', 'vm.json');
  }

  /// Loads and validates the config at [resolvePath], or throws
  /// [VmConfigError]. [output], if given, receives the permissions warning.
  static VmConfig load({Map<String, String>? environment, Output? output}) {
    final path = resolvePath(environment: environment);
    final file = File(path);
    if (!file.existsSync()) {
      throw VmConfigError(
        'no VM config at $path',
        details: 'see docs/vm-setup.md to create one',
      );
    }

    final mode = file.statSync().mode;
    if (isGroupOrOtherReadable(mode)) {
      output?.warn('$path is readable by group or other; chmod 600 it');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw VmConfigError('$path is not valid JSON', details: error.message);
    }
    if (decoded is! Map<String, dynamic>) {
      throw VmConfigError('$path must contain a JSON object');
    }
    return _fromJson(decoded, path, environment ?? Platform.environment);
  }

  static VmConfig _fromJson(
    Map<String, dynamic> json,
    String path,
    Map<String, String> environment,
  ) {
    final errors = <String>[];

    String? requireString(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        errors.add('"$key" must be a non-empty string');
        return null;
      }
      return value;
    }

    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String || value.isEmpty) {
        errors.add('"$key", if present, must be a non-empty string');
        return null;
      }
      return value;
    }

    final host = requireString('host');
    final user = requireString('user');
    final remoteWorkspace = requireString('remoteWorkspace');
    final identityFile = optionalString('identityFile');
    final flutterPath = optionalString('flutterPath');

    var port = 22;
    final rawPort = json['port'];
    if (rawPort is int) {
      port = rawPort;
    } else if (rawPort is String) {
      port = int.tryParse(rawPort) ?? -1;
    } else if (rawPort != null) {
      errors.add('"port" must be a number');
    }
    if (port < 1 || port > 65535) {
      errors.add('"port" must be between 1 and 65535');
    }

    if (host != null && !_hostPattern.hasMatch(host)) {
      errors.add('"host" (${_display(host)}) must match ${_hostPattern.pattern}');
    }
    if (user != null && !_userPattern.hasMatch(user)) {
      errors.add('"user" (${_display(user)}) must match ${_userPattern.pattern}');
    }
    _checkWindowsPath(remoteWorkspace, 'remoteWorkspace', errors);
    _checkWindowsPath(flutterPath, 'flutterPath', errors);
    if (identityFile != null && _whitespace.hasMatch(identityFile)) {
      errors.add('"identityFile" must not contain whitespace');
    }

    if (errors.isNotEmpty) {
      throw VmConfigError(
        '$path has invalid fields',
        details: errors.map((e) => '  $e').join('\n'),
      );
    }

    return VmConfig(
      host: host!,
      user: user!,
      remoteWorkspace: remoteWorkspace!,
      port: port,
      identityFile: _expandHome(identityFile, environment),
      flutterPath: flutterPath,
    );
  }

  static void _checkWindowsPath(String? value, String field, List<String> errors) {
    if (value == null) return;
    if (!_windowsPathPattern.hasMatch(value) || value.contains('..')) {
      errors.add('"$field" (${_display(value)}) must match '
          '${_windowsPathPattern.pattern} and must not contain ".."');
    }
  }

  static String _display(String value) => value.length > 60
      ? '${value.substring(0, 60)}...'
      : value;

  static String? _expandHome(String? path, Map<String, String> environment) {
    if (path == null || !path.startsWith('~')) return path;
    final home = environment['HOME'];
    if (home == null || home.isEmpty) return path;
    if (path == '~') return home;
    if (path.startsWith('~/')) return p.join(home, path.substring(2));
    return path;
  }
}
