import 'dart:io';
import 'dart:typed_data';

/// Writes raw [bytes] to [path], creating parent directories as needed.
String writeBytes(String path, List<int> bytes) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  return file.path;
}

/// Builds a minimal, syntactically valid PE header for testing —
/// just enough bytes for `validatePeHeader` to walk through every field.
/// Defaults describe a genuine PE32+ (x86-64) image.
Uint8List buildPeHeader({
  int lfanew = 0x80,
  int machine = 0x8664,
  int optionalMagic = 0x020b,
}) {
  final bytes = Uint8List(lfanew + 24 + 2);
  bytes[0] = 0x4d; // 'M'
  bytes[1] = 0x5a; // 'Z'
  ByteData.sublistView(bytes).setUint32(0x3c, lfanew, Endian.little);
  bytes[lfanew] = 0x50; // 'P'
  bytes[lfanew + 1] = 0x45; // 'E'
  bytes[lfanew + 2] = 0x00;
  bytes[lfanew + 3] = 0x00;
  ByteData.sublistView(bytes).setUint16(lfanew + 4, machine, Endian.little);
  ByteData.sublistView(bytes).setUint16(lfanew + 24, optionalMagic, Endian.little);
  return bytes;
}
