import 'package:test/test.dart';
import 'package:winbridge/src/package/signing.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  final arguments = signArguments(
    certificate: '/certs/app.pfx',
    input: '/out/setup.exe',
    output: '/out/setup.exe.signed',
    timestampUrl: Signer.defaultTimestampUrl,
  );

  // The rule this whole file exists to enforce: a signing passphrase never
  // reaches an argument vector. argv is world-readable through
  // /proc/<pid>/cmdline, and lands in shell history and CI logs besides.
  group('the passphrase never reaches argv', () {
    test('no argument carries a passphrase option', () {
      for (final forbidden in [
        '-pass',
        '-password',
        '-passin',
        '--password',
        '-p',
      ]) {
        expect(arguments, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('osslsigncode is told to read the passphrase, not given it', () {
      // -readpass takes a path; it is appended at call time pointing at a
      // 0700 temp file that is deleted in a finally block.
      expect(arguments, isNot(contains('-readpass')),
          reason: 'added only when a passphrase exists, never baked in');
    });

    test('the documented source is an environment variable', () {
      expect(Signer.passphraseVariable, 'WINBRIDGE_SIGN_PASSPHRASE');
    });

    test('no argument looks like a secret value', () {
      // A crude but effective canary: every argument is either a flag, a path
      // we constructed, or the timestamp URL.
      for (final argument in arguments) {
        expect(
          argument.startsWith('-') ||
              argument.startsWith('/') ||
              argument.startsWith('http') ||
              argument == 'sign' ||
              argument == 'sha256',
          isTrue,
          reason: 'unexpected argument "$argument"',
        );
      }
    });
  });

  group('argument construction', () {
    test('signs the right file to the right place with sha256', () {
      expect(arguments.first, 'sign');
      expect(arguments, containsAllInOrder(['-pkcs12', '/certs/app.pfx']));
      expect(arguments, containsAllInOrder(['-h', 'sha256']));
      expect(arguments, containsAllInOrder(['-in', '/out/setup.exe']));
      expect(
        arguments,
        containsAllInOrder(['-out', '/out/setup.exe.signed']),
        reason: 'osslsigncode cannot sign in place',
      );
    });

    test('timestamps by default, so signatures outlive the certificate', () {
      expect(arguments, containsAllInOrder(['-ts', Signer.defaultTimestampUrl]));
    });
  });

  group('when osslsigncode is missing', () {
    test('fails with guidance rather than shipping unsigned', () async {
      final home = tempDir('home');
      final pathDir = tempDir('path');
      final config =
          WinBridgeConfig(environment: {'HOME': home, 'PATH': pathDir});
      final signer = Signer(
        config: config,
        tools: ToolResolver(config: config),
        runner: RecordingProcessRunner(),
        output: silentOutput(),
      );

      expect(signer.isAvailable, isFalse);
      await expectLater(
        signer.sign(file: '/out/setup.exe', certificate: '/certs/app.pfx'),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('not signed'))
            .having((e) => e.details ?? '', 'details', contains('--sign'))),
      );
    });
  });
}
