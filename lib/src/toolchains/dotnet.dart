import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/build.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';

/// Publishes a .NET project for `win-x64`. Framework-dependent by default —
/// self-contained is a matter of passing `--self-contained true` through
/// `extraArguments`, since it is dotnet's own flag and BuildRequest carries
/// no toolchain-specific options of its own.
class DotnetToolchain implements Toolchain {
  const DotnetToolchain();

  @override
  String get id => 'dotnet';

  @override
  String get description =>
      'publishes .NET for win-x64 (framework-dependent by default)';

  @override
  bool canHandle(Project project) => project.type == ProjectType.dotnet;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(tool: 'dotnet', reason: 'publishes .NET for win-x64'),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final dotnet = request.tools.requirePath(
      'dotnet',
      reason: 'publishes .NET for win-x64',
    );

    final result = await request.runner.run(
      dotnet,
      [
        'publish',
        '-r', 'win-x64',
        '-c', 'Release',
        '--self-contained', 'false',
        '-o', request.outputDirectory,
        ...request.extraArguments,
      ],
      workingDirectory: request.project.root,
    );

    if (!result.ok) {
      return BuildResult.failure(
        'dotnet publish failed',
        details: result.diagnostics,
      );
    }

    // The apphost .exe is the only artifact reported. The managed assembly
    // published beside it is commonly built "Any CPU" (COFF machine 0x14C,
    // PE32 magic 0x10B) even under `-r win-x64` unless the project pins
    // PlatformTarget — that is normal for a framework-dependent publish, not
    // a broken build, so it is left off the artifact list rather than fed to
    // an x86-64 PE32+ check it was never going to pass.
    final exe = File(
      p.join(request.outputDirectory, '${request.project.name}.exe'),
    );
    if (!exe.existsSync()) {
      return BuildResult.failure(
        'dotnet publish produced no apphost .exe',
        details: 'expected ${exe.path}; WinBridge needs a native Windows '
            'launcher, not just the managed assembly — check that '
            'UseAppHost is not disabled in the project',
      );
    }

    return BuildResult.success(
      artifacts: [exe.path],
      summary: 'dotnet, win-x64',
      duration: result.duration,
    );
  }
}
