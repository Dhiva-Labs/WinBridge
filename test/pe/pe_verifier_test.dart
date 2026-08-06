import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_verifier.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import 'support.dart';

void main() {
  const verifier = PeVerifier();
  late String dir;

  setUp(() => dir = tempDir('pe'));

  test('name is shown in verbose output as PE32+ header', () {
    expect(verifier.name, 'PE32+ header');
  });

  test('accepts a valid PE32+ .exe', () async {
    final path = p.join(dir, 'app.exe');
    writeBytes(path, buildPeHeader());
    await expectLater(verifier.verify(path), completes);
  });

  test('accepts a valid PE32+ .dll', () async {
    final path = p.join(dir, 'app.dll');
    writeBytes(path, buildPeHeader());
    await expectLater(verifier.verify(path), completes);
  });

  test('extension check is case-insensitive', () async {
    final path = p.join(dir, 'app.EXE');
    writeBytes(path, buildPeHeader());
    await expectLater(verifier.verify(path), completes);
  });

  test('rejects an invalid .exe', () async {
    final path = p.join(dir, 'app.exe');
    writeFile(path, 'not a PE file');
    await expectLater(
      verifier.verify(path),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('app.exe'))),
    );
  });

  test('rejects an invalid .dll', () async {
    final path = p.join(dir, 'app.dll');
    writeFile(path, '\x7fELF garbage');
    await expectLater(
      verifier.verify(path),
      throwsA(isA<ArtifactFailure>()),
    );
  });

  test('ignores non-exe/dll artifacts entirely, valid or not', () async {
    final pdb = p.join(dir, 'app.pdb');
    writeFile(pdb, 'garbage, not a PE file at all');
    await expectLater(verifier.verify(pdb), completes);
  });
}
