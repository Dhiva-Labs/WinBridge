import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

class _RecordingVerifier implements ArtifactVerifier {
  final seen = <String>[];

  @override
  String get name => 'recording';

  @override
  Future<void> verify(String artifactPath) async => seen.add(artifactPath);
}

class _RejectingVerifier implements ArtifactVerifier {
  @override
  String get name => 'PE32+ header';

  @override
  Future<void> verify(String artifactPath) async =>
      throw const ArtifactFailure('not a Windows executable');
}

void main() {
  late String output;

  setUp(() => output = tempDir('out'));

  test('returns the resolved artifacts', () async {
    final exe = writeFile(p.join(output, 'app.exe'), 'MZ');
    expect(await verifyArtifacts([exe], outputDirectory: output), [exe]);
  });

  test('rejects a success with no artifacts', () {
    expect(
      () => verifyArtifacts(const [], outputDirectory: output),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('no artifacts'))),
    );
  });

  test('rejects an artifact that was never written', () {
    expect(
      () => verifyArtifacts([p.join(output, 'app.exe')],
          outputDirectory: output),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('was not produced'))),
    );
  });

  test('rejects an artifact outside the output directory', () {
    final stray = writeFile(p.join(tempDir('elsewhere'), 'app.exe'));
    expect(
      () => verifyArtifacts([stray], outputDirectory: output),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('escapes'))),
    );
  });

  test('rejects a symlink that leads outside', () {
    final stray = writeFile(p.join(tempDir('elsewhere'), 'payload'));
    final link = p.join(output, 'app.exe');
    Link(link).createSync(stray);
    expect(
      () => verifyArtifacts([link], outputDirectory: output),
      throwsA(isA<ArtifactFailure>()),
    );
  });

  test('rejects a directory', () {
    final directory = p.join(output, 'app.exe');
    Directory(directory).createSync();
    expect(
      () => verifyArtifacts([directory], outputDirectory: output),
      throwsA(isA<ArtifactFailure>()),
    );
  });

  test('rejects a relative path', () {
    expect(
      () => verifyArtifacts(['app.exe'], outputDirectory: output),
      throwsA(isA<ArtifactFailure>()),
    );
  });

  test('runs composed verifiers over every artifact', () async {
    final first = writeFile(p.join(output, 'a.exe'), 'MZ');
    final second = writeFile(p.join(output, 'b.dll'), 'MZ');
    final verifier = _RecordingVerifier();

    await verifyArtifacts([first, second],
        outputDirectory: output, verifiers: [verifier]);
    expect(verifier.seen, [first, second]);
  });

  test('a failing verifier fails the build', () {
    final exe = writeFile(p.join(output, 'app.exe'), '\x7fELF');
    expect(
      () => verifyArtifacts([exe],
          outputDirectory: output, verifiers: [_RejectingVerifier()]),
      throwsA(isA<ArtifactFailure>().having(
          (e) => e.message, 'message', 'not a Windows executable')),
    );
  });
}
