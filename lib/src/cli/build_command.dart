import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/artifact.dart';
import '../core/build.dart';
import '../core/config.dart';
import '../core/errors.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';
import 'command.dart';

class BuildCommand extends WinBridgeCommand {
  BuildCommand() {
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        valueHelp: 'dir',
        help: 'Where artifacts are written.\n'
            'Defaults to <project>/${WinBridgeConfig.defaultOutputDirectory}'
            '/<target>.',
      )
      ..addOption(
        'target',
        allowed: [for (final t in BuildTarget.all) t.slug],
        defaultsTo: BuildTarget.windowsX64.slug,
        help: 'Windows architecture to build for.',
      )
      ..addOption(
        'toolchain',
        valueHelp: 'id',
        help: 'Force a specific toolchain instead of the cheapest one that\n'
            'claims the project (see `winbridge doctor`).',
      )
      ..addFlag(
        'debug',
        negatable: false,
        help: 'Build unoptimized, with debug information.',
      );
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build a project for Windows.';

  @override
  String get invocation =>
      'winbridge build [directory] [-- extra tool arguments]';

  @override
  Future<int> run() async {
    final results = argResults!;
    final output = context.output;

    // The first positional is the directory; anything after it — in practice
    // everything past `--` — is passed through to the underlying tool as argv
    // elements. They are never joined into a string.
    final positional = results.rest;
    final directory = projectDirectory(positional);
    final extraArguments = positional.skip(1).toList();

    final target = BuildTarget.parse(results.option('target')!)!;
    final mode = results.flag('debug') ? BuildMode.debug : BuildMode.release;

    final project = detectProject(directory);
    final requested = results.option('toolchain');
    final toolchain = requested == null
        ? context.registry.forProject(project)
        : _namedToolchain(requested, project);
    if (toolchain == null) {
      throw BuildFailure(
        'no toolchain available for ${project.type.displayName}',
        details: context.registry.isEmpty
            ? 'no toolchain adapters are registered in this build'
            : 'registered: '
                '${context.registry.toolchains.map((t) => t.id).join(', ')}',
      );
    }

    final outputDirectory = _prepare(
      results.option('output') ??
          p.join(
            project.root,
            WinBridgeConfig.defaultOutputDirectory,
            target.slug,
          ),
    );
    final cacheDirectory = _prepare(
      context.config.buildCacheFor(toolchain.id) ??
          p.join(outputDirectory, '.cache'),
    );

    output.info('Building ${project.name} (${project.type.displayName}) '
        'for $target with ${toolchain.id}');
    output.detail('  output $outputDirectory');
    output.detail('  cache  $cacheDirectory');

    final result = await toolchain.build(BuildRequest(
      project: project,
      outputDirectory: outputDirectory,
      cacheDirectory: cacheDirectory,
      target: target,
      mode: mode,
      extraArguments: extraArguments,
      runner: context.processes,
      tools: context.tools,
      output: output,
    ));

    if (!result.succeeded) {
      throw BuildFailure(
        result.failureMessage ?? '${toolchain.id} build failed',
        details: result.details,
      );
    }

    final artifacts = await verifyArtifacts(
      result.artifacts,
      outputDirectory: outputDirectory,
      verifiers: context.verifiers,
    );

    output.blank();
    output.info('Built ${project.name} for $target'
        '${result.duration == null ? '' : ' in ${_seconds(result.duration!)}'}');
    if (result.summary != null) output.detail('  ${result.summary}');
    for (final artifact in artifacts) {
      output.info('  ${_display(artifact)}  ${_size(artifact)}');
    }
    return 0;
  }

  String _prepare(String directory) {
    final absolute = p.normalize(p.absolute(directory));
    try {
      Directory(absolute).createSync(recursive: true);
    } on FileSystemException catch (error) {
      throw BuildFailure(
        'could not create $absolute',
        details: error.osError?.message ?? error.message,
      );
    }
    return absolute;
  }

  /// Resolves `--toolchain <id>` to a registered adapter.
  ///
  /// A named toolchain that cannot build this project type is a usage error
  /// rather than a silent fallback: someone who asked for `msvc` on a Go
  /// project wants to be told, not quietly handed the Go adapter.
  Toolchain _namedToolchain(String id, Project project) {
    final toolchain = context.registry.byId(id);
    if (toolchain == null) {
      throw UsageFailure(
        'no toolchain called "$id"',
        details: 'registered: '
            '${context.registry.toolchains.map((t) => t.id).join(', ')}',
      );
    }
    if (!toolchain.canHandle(project)) {
      throw UsageFailure(
        'the $id toolchain does not build '
        '${project.type.displayName} projects',
        details: 'this one would: '
            '${context.registry.forProject(project)?.id ?? 'none registered'}',
      );
    }
    return toolchain;
  }

  /// Paths under the working directory read better relative.
  String _display(String path) {
    final relative = p.relative(path);
    return relative.startsWith('..') ? path : relative;
  }

  static String _size(String path) {
    final bytes = File(path).lengthSync();
    if (bytes < 1024) return '($bytes B)';
    if (bytes < 1024 * 1024) return '(${(bytes / 1024).toStringAsFixed(1)} KB)';
    return '(${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB)';
  }

  static String _seconds(Duration duration) =>
      '${(duration.inMilliseconds / 1000).toStringAsFixed(1)}s';
}
