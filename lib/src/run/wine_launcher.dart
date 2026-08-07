import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../pe/pe_header.dart';
import 'prefix.dart';
import 'wine_runtime.dart';

/// Everything one launch needs, resolved and validated.
class LaunchRequest {
  const LaunchRequest({
    required this.executable,
    required this.wine,
    required this.prefix,
    this.arguments = const [],
    this.verbose = false,
  });

  /// Absolute path to the `.exe`.
  final String executable;

  final ResolvedWine wine;
  final AppPrefix prefix;

  /// Passed through to the app untouched, as argv elements.
  final List<String> arguments;

  final bool verbose;
}

/// Runs a Windows executable under the managed Wine runtime.
class WineLauncher {
  const WineLauncher({required this.runner, required this.output});

  final ProcessRunner runner;
  final Output output;

  /// Reads the PE header before launching.
  ///
  /// Wine's own failure for a non-Windows binary is a wall of loader noise, so
  /// this answers the actual question first — is this even a Windows program —
  /// using the same header check `winbridge build` runs over its own output.
  static void checkExecutable(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw UsageFailure('no such file: $path');
    }
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      throw UsageFailure('not a file: $path');
    }
    final Uint8List head;
    try {
      final handle = file.openSync();
      try {
        // The header lives in the first few hundred bytes; a game's 800 MB
        // executable does not need reading to check it.
        head = handle.readSync(4096);
      } finally {
        handle.closeSync();
      }
    } on FileSystemException catch (error) {
      throw UsageFailure('cannot read $path', details: error.osError?.message);
    }
    validatePeHeader(head, label: p.basename(path));
  }

  /// The environment Wine is given. Separated out because it is exactly what
  /// the tests need to pin down, and because every entry here is a decision.
  static Map<String, String> environmentFor(LaunchRequest request) => {
        'WINEPREFIX': request.prefix.path,
        // Wine is chatty by default and none of it is the app's doing. Under
        // --verbose the user has asked to see everything, so the filter lifts
        // to Wine's own default rather than staying silent.
        if (!request.verbose) 'WINEDEBUG': '-all',
      };

  /// Launches and waits, returning the app's own exit code.
  Future<int> launch(LaunchRequest request) async {
    final workingDirectory = p.dirname(request.executable);

    Directory(request.prefix.path).createSync(recursive: true);

    final result = await runner.run(
      request.wine.binary,
      [request.executable, ...request.arguments],
      workingDirectory: workingDirectory,
      environment: environmentFor(request),
      // The app's output is what the user came for: always through, never
      // buffered, so a long-running program streams rather than accumulating.
      streamOutput: true,
      captureOutput: false,
    );
    return result.exitCode;
  }
}
