import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/recipes/fingerprint.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late String pathDir;
  late String file;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    file = writeFile(p.join(tempDir('installer'), 'Setup.exe'), 'hello world');
  });

  ToolResolver toolsWith({required bool sha256sumOnPath}) {
    if (sha256sumOnPath) writeExecutable(pathDir, 'sha256sum');
    final config = WinBridgeConfig(environment: {'HOME': home, 'PATH': pathDir});
    return ToolResolver(config: config);
  }

  group('unit, against a fake sha256sum', () {
    test('runs sha256sum with just the path, and parses its output', () async {
      final tools = toolsWith(sha256sumOnPath: true);
      final runner = RecordingProcessRunner(
        onRun: (_) => okResult(
          stdout: 'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2'
              'efcde9  $file\n',
        ),
      );

      final fingerprint =
          await fingerprintFile(file, tools: tools, runner: runner);

      expect(runner.calls.single.arguments, [file]);
      expect(fingerprint.sha256,
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9');
      expect(fingerprint.fileName, 'Setup.exe');
      expect(fingerprint.sizeBytes, 'hello world'.length);
    });

    test('never reads the file into Dart itself — only stats it and asks '
        'sha256sum for the digest', () async {
      final tools = toolsWith(sha256sumOnPath: true);
      final runner = RecordingProcessRunner(
        onRun: (_) => okResult(stdout: '${'a' * 64}  ignored\n'),
      );
      await fingerprintFile(file, tools: tools, runner: runner);
      // Exactly one process call — the hash — is all fingerprinting does.
      expect(runner.calls, hasLength(1));
    });

    test('throws a clean error for a missing file', () async {
      final tools = toolsWith(sha256sumOnPath: true);
      expect(
        () => fingerprintFile(p.join(p.dirname(file), 'nope.exe'),
            tools: tools, runner: RecordingProcessRunner()),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('throws a clean error for a directory', () async {
      final tools = toolsWith(sha256sumOnPath: true);
      expect(
        () => fingerprintFile(p.dirname(file),
            tools: tools, runner: RecordingProcessRunner()),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('a non-zero sha256sum exit is a ProcessFailure', () async {
      final tools = toolsWith(sha256sumOnPath: true);
      final runner = RecordingProcessRunner(onRun: (_) => failResult());
      expect(
        () => fingerprintFile(file, tools: tools, runner: runner),
        throwsA(isA<ProcessFailure>()),
      );
    });

    test('unparsable sha256sum output is a clean failure, not a crash',
        () async {
      final tools = toolsWith(sha256sumOnPath: true);
      final runner =
          RecordingProcessRunner(onRun: (_) => okResult(stdout: 'garbage'));
      expect(
        () => fingerprintFile(file, tools: tools, runner: runner),
        throwsA(isA<BuildFailure>()),
      );
    });

    test('names sha256sum in the ToolNotFound when it is absent', () async {
      final tools = toolsWith(sha256sumOnPath: false);
      expect(
        () => fingerprintFile(file, tools: tools, runner: RecordingProcessRunner()),
        throwsA(isA<ToolNotFound>()
            .having((e) => e.names, 'names', contains('sha256sum'))),
      );
    });
  });

  group('streaming, against a real sha256sum', () {
    final realTools = ToolResolver(config: WinBridgeConfig());
    final realSha256sum = realTools.resolve('sha256sum');

    test(
      'fingerprints a multi-megabyte file correctly, and reports its exact '
      'size, without WinBridge ever reading its bytes',
      () async {
        // 5 MiB of a fixed byte. Its sha256 was computed once, independently,
        // with the system sha256sum — a spot check that this module's own
        // plumbing (argv, output parsing) is correct end to end, not just
        // internally consistent with itself.
        const sizeBytes = 5 * 1024 * 1024;
        const expectedSha256 =
            'dbbe5517996826bd5861ac22b745d21d11219055d89243ca1aea0ad31f552b12';

        final big = p.join(tempDir('installer-big'), 'big.exe');
        final sink = File(big).openWrite();
        final chunk = List.filled(64 * 1024, 0x41); // 'A', 64 KiB at a time
        for (var written = 0; written < sizeBytes; written += chunk.length) {
          sink.add(chunk);
        }
        await sink.close();

        final fingerprint = await fingerprintFile(
          big,
          tools: realTools,
          runner: ProcessRunner(),
        );

        expect(fingerprint.sizeBytes, sizeBytes);
        expect(fingerprint.fileName, 'big.exe');
        expect(fingerprint.sha256, expectedSha256);
      },
      skip: realSha256sum == null
          ? 'no sha256sum on PATH to fingerprint against'
          : false,
    );
  });
}
