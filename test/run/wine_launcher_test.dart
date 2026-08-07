import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/src/run/wine_launcher.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/winbridge.dart';

import '../pe/support.dart';
import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  late String appDir;
  late String exe;
  late String prefixDir;

  setUp(() {
    appDir = tempDir('app');
    exe = p.join(appDir, 'hello.exe');
    File(exe).writeAsBytesSync(buildPeHeader());
    prefixDir = p.join(tempDir('prefixes'), 'hello');
  });

  LaunchRequest requestWith({
    List<String> arguments = const [],
    bool verbose = false,
  }) =>
      LaunchRequest(
        executable: exe,
        wine: const ResolvedWine(
          binary: '/rt/bin/wine',
          source: WineSource.managed,
          runtimeDirectory: '/rt',
        ),
        prefix: AppPrefix(name: 'hello', path: prefixDir),
        arguments: arguments,
        verbose: verbose,
      );

  group('environment', () {
    test('points Wine at this app prefix and silences its own logging', () {
      expect(WineLauncher.environmentFor(requestWith()), {
        'WINEPREFIX': prefixDir,
        'WINEDEBUG': '-all',
      });
    });

    test('--verbose lifts the log filter rather than adding to it', () {
      final env = WineLauncher.environmentFor(requestWith(verbose: true));
      expect(env.containsKey('WINEDEBUG'), isFalse);
      expect(env['WINEPREFIX'], prefixDir);
    });

    test('is an overlay of exactly these keys, nothing inherited or invented',
        () {
      expect(WineLauncher.environmentFor(requestWith()).keys,
          unorderedEquals(['WINEPREFIX', 'WINEDEBUG']));
    });
  });

  group('argv', () {
    test('is wine, the exe, then the app arguments verbatim', () async {
      final runner = RecordingProcessRunner();
      await WineLauncher(runner: runner, output: silentOutput())
          .launch(requestWith(arguments: ['--flag', 'a b', r'$(whoami)']));

      final call = runner.calls.single;
      expect(call.executable, '/rt/bin/wine');
      expect(call.arguments, [exe, '--flag', 'a b', r'$(whoami)']);
    });

    test('runs in the executable\'s own directory', () async {
      // Apps routinely load DLLs and data files from beside themselves.
      final runner = RecordingProcessRunner();
      await WineLauncher(runner: runner, output: silentOutput())
          .launch(requestWith());
      expect(runner.calls.single.workingDirectory, appDir);
    });

    test('streams the app output instead of buffering it', () async {
      final runner = RecordingProcessRunner();
      await WineLauncher(runner: runner, output: silentOutput())
          .launch(requestWith());

      final call = runner.calls.single;
      expect(call.streamOutput, isTrue);
      expect(call.captureOutput, isFalse,
          reason: 'a long-running app must not accumulate output in memory');
    });

    test('creates the prefix directory before launching', () async {
      expect(Directory(prefixDir).existsSync(), isFalse);
      await WineLauncher(runner: RecordingProcessRunner(), output: silentOutput())
          .launch(requestWith());
      expect(Directory(prefixDir).existsSync(), isTrue);
    });

    test('returns the app\'s own exit code', () async {
      final runner = RecordingProcessRunner(
        onRun: (_) => failResult(exitCode: 42),
      );
      final code = await WineLauncher(runner: runner, output: silentOutput())
          .launch(requestWith());
      expect(code, 42);
    });
  });

  group('checkExecutable', () {
    test('accepts a real PE32+ image', () {
      expect(() => WineLauncher.checkExecutable(exe), returnsNormally);
    });

    test('rejects an ELF binary with a message that explains it', () {
      final elf = p.join(appDir, 'linux-binary');
      File(elf).writeAsBytesSync(
        Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00]),
      );
      expect(
        () => WineLauncher.checkExecutable(elf),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('ELF'))),
      );
    });

    test('rejects a 32-bit PE', () {
      final pe32 = p.join(appDir, 'old.exe');
      File(pe32).writeAsBytesSync(buildPeHeader(optionalMagic: 0x010b));
      expect(
        () => WineLauncher.checkExecutable(pe32),
        throwsA(isA<ArtifactFailure>()),
      );
    });

    test('rejects a missing file as a usage error', () {
      expect(
        () => WineLauncher.checkExecutable(p.join(appDir, 'nope.exe')),
        throwsA(isA<UsageFailure>()
            .having((e) => e.exitCode, 'exitCode', 2)),
      );
    });

    test('rejects a directory', () {
      expect(
        () => WineLauncher.checkExecutable(appDir),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('reads only the header, not the whole file', () {
      // A game executable can be hundreds of megabytes; the header is in the
      // first few hundred bytes.
      final big = p.join(appDir, 'big.exe');
      final bytes = [...buildPeHeader(), ...List.filled(2 * 1024 * 1024, 0)];
      File(big).writeAsBytesSync(bytes);
      expect(() => WineLauncher.checkExecutable(big), returnsNormally);
    });
  });
}
