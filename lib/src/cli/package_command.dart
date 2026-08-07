import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../package/installer_builder.dart';
import '../package/nsis_script.dart';
import '../package/signing.dart';
import '../pe/pe_header.dart';
import '../run/wine_runtime.dart';
import 'command.dart';

/// `winbridge package <dir>` — turn built artifacts into a Windows installer.
class PackageCommand extends WinBridgeCommand {
  PackageCommand() {
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'file',
        help: 'Installer to write.\n'
            'Defaults to <artifacts>/<app>-<version>-setup.exe.',
      )
      ..addOption(
        'artifacts',
        valueHelp: 'dir',
        help: 'Directory holding the built files.\n'
            'Defaults to the directory `winbridge build` writes to.',
      )
      ..addOption(
        'script',
        valueHelp: 'file.nsi',
        help: 'Use this NSIS script instead of generating one.',
      )
      ..addOption(
        'app-version',
        valueHelp: 'x.y.z',
        help: 'Version recorded in the installer. Defaults to 0.0.0.',
      )
      ..addOption(
        'sign',
        valueHelp: 'cert.pfx',
        help: 'Authenticode-sign the installer with this PKCS#12 certificate.\n'
            'The passphrase comes from \$${Signer.passphraseVariable} or an '
            'interactive prompt — never from the command line.',
      );
  }

  @override
  String get name => 'package';

  @override
  String get description => 'Build a Windows installer from built artifacts.';

  @override
  String get invocation => 'winbridge package [directory]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final output = context.output;

    final directory = projectDirectory(results.rest);
    final project = detectProject(directory);

    final artifactDirectory = p.normalize(p.absolute(
      results.option('artifacts') ??
          p.join(
            project.root,
            WinBridgeConfig.defaultOutputDirectory,
            'windows-x64',
          ),
    ));
    if (!Directory(artifactDirectory).existsSync()) {
      throw UsageFailure(
        'no built artifacts at $artifactDirectory',
        details: 'run `winbridge build ${p.relative(project.root)}` first, '
            'or point --artifacts at the directory holding them',
      );
    }

    final files = _collectArtifacts(artifactDirectory);
    if (files.isEmpty) {
      throw UsageFailure(
        'no files to package in $artifactDirectory',
      );
    }
    final mainExecutable = _mainExecutable(files, project.name);
    if (mainExecutable == null) {
      throw UsageFailure(
        'no .exe found in $artifactDirectory',
        details: 'an installer needs something to install',
      );
    }

    final version = results.option('app-version') ?? '0.0.0';
    final installerPath = p.normalize(p.absolute(
      results.option('output') ??
          p.join(artifactDirectory, '${project.name}-$version-setup.exe'),
    ));

    final wine = await WineRuntime(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    ).resolveOrInstall();

    final builder = InstallerBuilder(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    );
    if (!builder.isNsisInstalled) {
      output.info('Installing NSIS (2 MB) to build the installer');
    }

    output.info('Packaging ${project.name} $version '
        '(${files.length} file${files.length == 1 ? '' : 's'})');

    final script = results.option('script');
    final String installer;
    if (script != null) {
      final scriptPath = p.normalize(p.absolute(script));
      if (!File(scriptPath).existsSync()) {
        throw UsageFailure('no such NSIS script: $script');
      }
      installer = await builder.compile(
        scriptPath: scriptPath,
        outputFile: installerPath,
        wine: wine,
        verbose: output.verbose,
      );
    } else {
      installer = await builder.buildDefaultInstaller(
        spec: InstallerSpec(
          appName: project.name,
          version: version,
          mainExecutable: mainExecutable,
          files: files,
          outputFile: p.basename(installerPath),
        ),
        workingDirectory: artifactDirectory,
        destination: installerPath,
        wine: wine,
        verbose: output.verbose,
      );
    }

    // The installer gets checked too, but not against the x86-64 rule `build`
    // applies to its own artifacts: NSIS emits a 32-bit installer on purpose,
    // so that it runs on any Windows regardless of what it installs.
    final machine = validatePeImage(
      File(installer).readAsBytesSync(),
      label: p.basename(installer),
    );
    output.detail('installer is a ${describeMachine(machine)} PE image');

    if (results.option('sign') case final certificate?) {
      output.info('Signing ${p.basename(installer)}');
      await Signer(
        config: context.config,
        tools: context.tools,
        runner: context.processes,
        output: output,
      ).sign(
        file: installer,
        certificate: p.normalize(p.absolute(certificate)),
        verbose: output.verbose,
      );
    }

    output.blank();
    output.info('Built ${_display(installer)}  ${_size(installer)}');
    return 0;
  }

  /// Everything in the artifact directory except things a previous packaging
  /// run left behind — an installer must not ship the last installer.
  List<String> _collectArtifacts(String directory) {
    final files = <String>[
      for (final entry in Directory(directory).listSync(followLinks: false))
        if (entry is File && !_isPackagingOutput(entry.path)) entry.path,
    ];
    files.sort();
    return files;
  }

  static bool _isPackagingOutput(String path) {
    final name = p.basename(path).toLowerCase();
    return name.endsWith('-setup.exe') || name.endsWith('.nsi');
  }

  /// The executable a shortcut should point at: the one named after the
  /// project if it is there, otherwise the only one, otherwise the first by
  /// name so the choice is at least deterministic.
  static String? _mainExecutable(List<String> files, String appName) {
    final executables =
        files.where((f) => p.extension(f).toLowerCase() == '.exe').toList();
    if (executables.isEmpty) return null;
    for (final candidate in executables) {
      if (p.basenameWithoutExtension(candidate) == appName) return candidate;
    }
    return executables.first;
  }

  static String _display(String path) {
    final relative = p.relative(path);
    return relative.startsWith('..') ? path : relative;
  }

  static String _size(String path) {
    final bytes = File(path).lengthSync();
    if (bytes < 1024) return '($bytes B)';
    if (bytes < 1024 * 1024) return '(${(bytes / 1024).toStringAsFixed(1)} KB)';
    return '(${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB)';
  }
}
