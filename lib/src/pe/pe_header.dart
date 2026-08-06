import 'dart:typed_data';

import '../core/errors.dart';

/// Windows machine-type constants worth naming in a failure message. Not
/// exhaustive — anything else is reported by its raw value.
const _machineNames = {
  0x014c: 'i386 (32-bit)',
  0x01c0: 'ARM',
  0x01c4: 'ARMNT',
  0x0200: 'IA64',
  0x8664: 'x86-64',
  0xaa64: 'ARM64',
};

const _machineX64 = 0x8664;
const _magicPe32 = 0x010b;
const _magicPe32Plus = 0x020b;

/// Checks [bytes] against the PE32+ header a WinBridge build is expected to
/// produce: a DOS stub starting `MZ`, an `e_lfanew` pointer at 0x3C into a
/// `PE\0\0` signature, a COFF header naming the x86-64 machine type, and an
/// optional header whose magic is 0x20B (PE32+, not the 32-bit PE32).
///
/// Throws [ArtifactFailure] naming which check failed and what was found
/// instead, so a misconfigured cross-compiler's ELF or 32-bit output reads as
/// an explanation rather than a mystery.
void validatePeHeader(Uint8List bytes, {required String label}) {
  Never fail(String message, {String? found}) {
    throw ArtifactFailure(
      '$label is not a Windows PE32+ (x86-64) executable: $message',
      details: found == null ? null : 'found: $found',
    );
  }

  if (_looksLikeElf(bytes)) {
    fail(
      'this is an ELF binary, not a PE image',
      found: 'ELF ${_elfClass(bytes)}',
    );
  }

  if (bytes.length < 2 || bytes[0] != 0x4d || bytes[1] != 0x5a) {
    fail(
      "missing the 'MZ' DOS header magic",
      found: bytes.isEmpty ? 'an empty file' : _hex(bytes, 0, 2),
    );
  }

  if (bytes.length < 0x3c + 4) {
    fail(
      'truncated before e_lfanew (offset 0x3C)',
      found: '${bytes.length} byte(s)',
    );
  }

  final lfanew = _u32(bytes, 0x3c);
  if (lfanew < 0 || lfanew + 4 > bytes.length) {
    fail(
      'e_lfanew points outside the file',
      found: 'offset 0x${lfanew.toRadixString(16)} in a '
          '${bytes.length}-byte file',
    );
  }

  if (bytes[lfanew] != 0x50 ||
      bytes[lfanew + 1] != 0x45 ||
      bytes[lfanew + 2] != 0x00 ||
      bytes[lfanew + 3] != 0x00) {
    fail(
      "missing the 'PE\\0\\0' signature at e_lfanew (0x"
      '${lfanew.toRadixString(16)})',
      found: _hex(bytes, lfanew, 4),
    );
  }

  // The COFF file header immediately follows the signature: Machine (2),
  // NumberOfSections (2), TimeDateStamp (4), PointerToSymbolTable (4),
  // NumberOfSymbols (4), SizeOfOptionalHeader (2), Characteristics (2).
  final coff = lfanew + 4;
  const coffHeaderSize = 20;
  if (coff + coffHeaderSize > bytes.length) {
    fail('truncated COFF header', found: '${bytes.length} byte(s)');
  }

  final machine = _u16(bytes, coff);
  if (machine != _machineX64) {
    fail(
      'unsupported machine type (want x86-64 / 0x8664)',
      found: '0x${machine.toRadixString(16).padLeft(4, '0')}'
          '${_machineNames[machine] == null ? '' : ' (${_machineNames[machine]})'}',
    );
  }

  final optionalHeader = coff + coffHeaderSize;
  if (optionalHeader + 2 > bytes.length) {
    fail('truncated optional header', found: '${bytes.length} byte(s)');
  }

  final magic = _u16(bytes, optionalHeader);
  if (magic != _magicPe32Plus) {
    fail(
      'not a PE32+ (64-bit) image (want optional-header magic 0x20B)',
      found: '0x${magic.toRadixString(16).padLeft(4, '0')}'
          '${magic == _magicPe32 ? ' (PE32, 32-bit)' : ''}',
    );
  }
}

bool _looksLikeElf(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x7f &&
    bytes[1] == 0x45 &&
    bytes[2] == 0x4c &&
    bytes[3] == 0x46;

String _elfClass(Uint8List bytes) {
  if (bytes.length < 5) return 'unknown class';
  switch (bytes[4]) {
    case 1:
      return '32-bit';
    case 2:
      return '64-bit';
    default:
      return 'unknown class';
  }
}

String _hex(Uint8List bytes, int offset, int length) {
  final end = (offset + length).clamp(0, bytes.length);
  final start = offset.clamp(0, end);
  return bytes
      .sublist(start, end)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}

int _u16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);

int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
