import 'command.dart';

class DetectCommand extends WinBridgeCommand {
  @override
  String get name => 'detect';

  @override
  String get description => 'Report the project type found in a directory.';

  @override
  String get invocation => 'winbridge detect [directory]';

  @override
  Future<int> run() async {
    final output = context.output;
    final directory = projectDirectory(argResults!.rest);
    final project = detectProject(directory);
    final toolchains = context.registry.allFor(project);

    output.info('Project    ${project.name}');
    output.info('Type       ${project.type.displayName}');
    output.info('Root       ${project.root}');
    output.info('Detected   ${project.primaryEvidence}');

    if (toolchains.isEmpty) {
      output.info('Toolchain  none registered for ${project.type.displayName}');
    } else {
      output.info('Toolchain  ${toolchains.first.id}'
          ' (${toolchains.first.description})');
      for (final alternative in toolchains.skip(1)) {
        output.detail('           also: ${alternative.id}'
            ' (${alternative.description})');
      }
    }

    for (final other in project.otherEvidence) {
      output.detail('Also       $other -> ${other.type.displayName}');
    }
    return 0;
  }
}
