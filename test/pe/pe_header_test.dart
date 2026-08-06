import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:winbridge/src/pe/pe_header.dart';
import 'package:winbridge/winbridge.dart';

import 'support.dart';

void main() {
  test('accepts a genuine PE32+ (x86-64) header', () {
    expect(
      () => validatePeHeader(buildPeHeader(), label: 'app.exe'),
      returnsNormally,
    );
  });

  test('accepts a header at a non-default e_lfanew offset', () {
    expect(
      () => validatePeHeader(buildPeHeader(lfanew: 0xf0), label: 'app.exe'),
      returnsNormally,
    );
  });

  test('rejects an empty file', () {
    expect(
      () => validatePeHeader(Uint8List(0), label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('app.exe'))
          .having((e) => e.message, 'message', contains('MZ'))),
    );
  });

  test('rejects a file missing the MZ magic', () {
    final bytes = buildPeHeader();
    bytes[0] = 0x00;
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('MZ'))),
    );
  });

  test('rejects an ELF binary with a specific message', () {
    final elf = Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 0x02, 0, 0, 0]);
    expect(
      () => validatePeHeader(elf, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('ELF'))
          .having((e) => e.details, 'details', contains('64-bit'))),
    );
  });

  group('truncation', () {
    test('cut right after the MZ magic (before e_lfanew)', () {
      final bytes = buildPeHeader().sublist(0, 10);
      expect(
        () => validatePeHeader(bytes, label: 'app.exe'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('e_lfanew'))),
      );
    });

    test('cut before the full 4-byte PE signature is present', () {
      final full = buildPeHeader();
      final bytes = full.sublist(0, 0x80 + 2);
      expect(
        () => validatePeHeader(bytes, label: 'app.exe'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('e_lfanew'))),
      );
    });

    test('cut inside the COFF header, after the signature', () {
      final full = buildPeHeader();
      final bytes = full.sublist(0, 0x80 + 4 + 10);
      expect(
        () => validatePeHeader(bytes, label: 'app.exe'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('COFF header'))),
      );
    });

    test('cut inside the optional header magic', () {
      final full = buildPeHeader();
      final bytes = full.sublist(0, 0x80 + 24 + 1);
      expect(
        () => validatePeHeader(bytes, label: 'app.exe'),
        throwsA(isA<ArtifactFailure>()
            .having((e) => e.message, 'message', contains('optional header'))),
      );
    });
  });

  test('rejects a missing PE signature at e_lfanew', () {
    final bytes = buildPeHeader();
    bytes[0x80] = 0x00;
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('PE'))),
    );
  });

  test('rejects the wrong machine type, naming what was found', () {
    final bytes = buildPeHeader(machine: 0x014c); // i386
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('machine'))
          .having((e) => e.details, 'details', contains('014c'))),
    );
  });

  test('rejects arm64', () {
    final bytes = buildPeHeader(machine: 0xaa64);
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.details, 'details', contains('ARM64'))),
    );
  });

  test('rejects PE32 (32-bit) optional header magic 0x10B', () {
    final bytes = buildPeHeader(optionalMagic: 0x010b);
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', contains('PE32+'))
          .having((e) => e.details, 'details', contains('PE32'))),
    );
  });

  test('rejects an unrecognized optional header magic', () {
    final bytes = buildPeHeader(optionalMagic: 0x9999);
    expect(
      () => validatePeHeader(bytes, label: 'app.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.details, 'details', contains('9999'))),
    );
  });

  test('the label appears in the failure message', () {
    expect(
      () => validatePeHeader(Uint8List(0), label: 'weird-name.exe'),
      throwsA(isA<ArtifactFailure>()
          .having((e) => e.message, 'message', startsWith('weird-name.exe'))),
    );
  });
}
