import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:winbridge/winbridge.dart';

import 'remote_command.dart';
import 'vm_config.dart';
import 'vm_transport.dart';

/// Builds a Flutter Windows app on the headless KVM VM described by
/// `~/.config/winbridge/vm.json`, registered last so a project that a native
/// cross-compiler can already handle never has to touch the network.
///
/// The sequence: load and validate the VM config, sync the project across
/// (excluding `build/`, `.dart_tool/` and `.git/`), run `flutter pub get`,
/// create the `windows/` platform folder on the VM if the synced tree does
/// not already have one, run `flutter build windows --release`, then fetch
/// the release runner directory back. Any step failing returns
/// [BuildResult.failure] carrying that step's own output — nothing here
/// throws for an ordinary build failure.
class FlutterVmToolchain implements Toolchain {
  FlutterVmToolchain({
    Map<String, String>? environment,
    VmTransport Function(VmConfig config, BuildRequest request)? transportFactory,
  })  : _environment = environment,
        _transportFactory = transportFactory ?? _defaultTransport;

  final Map<String, String>? _environment;
  final VmTransport Function(VmConfig config, BuildRequest request) _transportFactory;

  static VmTransport _defaultTransport(VmConfig config, BuildRequest request) =>
      OpenSshTransport(config: config, runner: request.runner, tools: request.tools);

  @override
  String get id => 'vm';

  @override
  String get description => 'Builds Flutter for Windows on a headless KVM VM over SSH.';

  @override
  bool canHandle(Project project) => project.type == ProjectType.flutter;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(
          tool: 'ssh',
          reason: 'connects to the build VM',
        ),
        ToolRequirement(
          tool: 'rsync',
          reason: 'syncs sources to and artifacts from the build VM',
        ),
        // Not a resolvable executable — this row exists purely so `winbridge
        // doctor` reminds a user that the VM path needs more than binaries on
        // PATH. `winbridge vm doctor` does the real check.
        ToolRequirement(
          tool: 'configured vm',
          reason: 'run `winbridge vm doctor` after writing '
              '~/.config/winbridge/vm.json (see docs/vm-setup.md)',
          optional: true,
        ),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final started = DateTime.now();
    try {
      return await _build(request, started);
    } on WinBridgeException catch (error) {
      // Config validation, and the defensive checks in `fetchTree` and
      // `_collectArtifacts`, raise the same exception types the CLI's own
      // post-build verification does. Those are build outcomes, so they are
      // reported the same way every other failure in this method is: a
      // result, not a stack trace.
      return BuildResult.failure(
        error.message,
        details: error.details,
        duration: DateTime.now().difference(started),
      );
    }
  }

  Future<BuildResult> _build(BuildRequest request, DateTime started) async {
    final config = VmConfig.load(environment: _environment, output: request.output);
    final transport = _transportFactory(config, request);
    final commands = RemoteCommands(config);

    final send = await transport.sendTree(
      request.project.root,
      commands.remoteProjectDir,
    );
    if (!send.ok) return _fail('sync to vm failed', send, started);

    final pubGet = await transport.run(commands.pubGet());
    if (!pubGet.ok) {
      return _fail('flutter pub get failed on the vm', pubGet, started);
    }

    final ensureWindows = await transport.run(commands.ensureWindowsPlatform());
    if (!ensureWindows.ok) {
      return _fail(
        'flutter create --platforms=windows failed on the vm',
        ensureWindows,
        started,
      );
    }

    final build = await transport.run(commands.buildWindowsRelease());
    if (!build.ok) {
      return _fail('flutter build windows failed on the vm', build, started);
    }

    final fetch = await transport.fetchTree(
      commands.remoteReleaseDir,
      request.outputDirectory,
    );
    if (!fetch.ok) {
      return _fail('fetching build output from the vm failed', fetch, started);
    }

    final artifacts = _collectArtifacts(request.outputDirectory);
    if (artifacts.isEmpty) {
      return BuildResult.failure(
        'the vm build produced no files in ${request.outputDirectory}',
      );
    }

    return BuildResult.success(
      artifacts: artifacts,
      summary: 'flutter (vm) windows/${request.target.arch.name}',
      duration: DateTime.now().difference(started),
    );
  }

  static BuildResult _fail(String message, RunResult result, DateTime started) =>
      BuildResult.failure(
        message,
        details: result.diagnostics,
        duration: DateTime.now().difference(started),
      );

  /// The fetched Release directory holds the `.exe` plus its DLLs and `data/`
  /// folder. Every entry is re-validated with [requireInside] even though
  /// [OpenSshTransport.fetchTree] already checked on the way in — the CLI's
  /// own [verifyArtifacts] repeats this again after `build` returns, and an
  /// adapter is not supposed to rely on a check happening somewhere else.
  static List<String> _collectArtifacts(String outputDirectory) {
    final exeFiles = <String>[];
    final otherFiles = <String>[];
    for (final entity
        in Directory(outputDirectory).listSync(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw ArtifactFailure(
          'a symlink landed in the output directory: ${entity.path}',
          details: 'build output must be regular files only',
        );
      }
      if (entity is! File) continue;
      requireInside(
        parent: outputDirectory,
        child: entity.path,
        what: 'artifact ${p.basename(entity.path)}',
      );
      final real = realPath(entity.path);
      if (p.extension(entity.path).toLowerCase() == '.exe') {
        exeFiles.add(real);
      } else {
        otherFiles.add(real);
      }
    }
    exeFiles.sort();
    otherFiles.sort();
    return [...exeFiles, ...otherFiles];
  }
}
