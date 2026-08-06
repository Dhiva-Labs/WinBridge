import 'package:path/path.dart' as p;

import '../core/build.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';

/// Cross-compiles a Go module with the toolchain's own `GOOS`/`GOARCH`
/// support — no external cross-compiler needed.
class GoToolchain implements Toolchain {
  const GoToolchain();

  @override
  String get id => 'go';

  @override
  String get description => 'cross-compiles Go via GOOS=windows GOARCH=amd64';

  @override
  bool canHandle(Project project) => project.type == ProjectType.go;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(
          tool: 'go',
          reason: 'cross-compiles Go for windows/amd64',
        ),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final go = request.tools.requirePath(
      'go',
      reason: 'cross-compiles Go for windows/amd64',
    );
    final exe = p.join(request.outputDirectory, '${request.project.name}.exe');

    final result = await request.runner.run(
      go,
      [
        'build',
        if (request.mode.isRelease) ...['-ldflags', '-s -w'],
        '-o', exe,
        ...request.extraArguments,
        '.',
      ],
      workingDirectory: request.project.root,
      environment: {
        'GOOS': 'windows',
        'GOARCH': request.target.arch == TargetArch.arm64 ? 'arm64' : 'amd64',
        'CGO_ENABLED': '0',
        'GOCACHE': p.join(request.cacheDirectory, 'go-build'),
      },
    );

    if (!result.ok) {
      return BuildResult.failure('go build failed', details: result.diagnostics);
    }
    return BuildResult.success(
      artifacts: [exe],
      summary: 'go, windows/${request.target.arch == TargetArch.arm64 ? 'arm64' : 'amd64'}',
      duration: result.duration,
    );
  }
}
