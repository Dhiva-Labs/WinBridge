import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../detect/detector.dart';
import '../detect/project.dart';
import 'context.dart';
import 'runner.dart';

/// Shared plumbing for the WinBridge subcommands.
abstract class WinBridgeCommand extends Command<int> {
  WinBridgeContext get context => (runner! as WinBridgeRunner).context;

  /// The optional `[directory]` positional, defaulting to the working
  /// directory. A path that is not a directory is a usage error, not a build
  /// failure — the command line was wrong before any work started.
  String projectDirectory(Iterable<String> positional) {
    final raw = positional.isEmpty ? '.' : positional.first;
    final directory = p.normalize(p.absolute(raw));
    final type = FileSystemEntity.typeSync(directory);
    if (type == FileSystemEntityType.notFound) {
      throw UsageFailure('no such directory: $raw');
    }
    if (type != FileSystemEntityType.directory) {
      throw UsageFailure('not a directory: $raw');
    }
    return directory;
  }

  Project detectProject(String directory) {
    final project = context.detector.detect(directory);
    if (project == null) {
      throw DetectionFailure(
        'no supported project found in $directory',
        details: [
          'winbridge looks for, in this order:',
          ...ProjectDetector.markers.map((marker) => '  $marker'),
        ].join('\n'),
      );
    }
    return project;
  }
}
