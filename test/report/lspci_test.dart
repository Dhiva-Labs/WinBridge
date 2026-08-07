import 'package:test/test.dart';
import 'package:winbridge/src/report/lspci.dart';

// A captured `lspci -nn` block: a VGA controller, an unrelated audio device
// (must be skipped), a secondary 3D controller (hybrid-graphics laptop), a
// network card (must be skipped), and a blank line. Real `lspci -nn` output
// has all of these.
const _lspciSample = '''
00:02.0 VGA compatible controller [0300]: Intel Corporation TigerLake-LP GT2 [Iris Xe Graphics] [8086:9a49] (rev 01)
00:1f.3 Audio device [0403]: Intel Corporation Tiger Lake-LP Smart Sound Technology Audio Controller [8086:a0c8]

01:00.0 3D controller [0302]: NVIDIA Corporation GA104M [GeForce RTX 3070 Mobile / Max-Q] [10de:249d] (rev a1)
02:00.0 Ethernet controller [0200]: Intel Corporation Ethernet Connection [8086:15f2] (rev 06)''';

void main() {
  group('parseLspciGpuLines', () {
    final devices = parseLspciGpuLines(_lspciSample);

    test('finds only the VGA and 3D controller lines', () {
      expect(devices, hasLength(2));
    });

    test('parses the primary VGA controller', () {
      final vga = devices.firstWhere((d) => d.className == 'VGA compatible controller');
      expect(vga.busId, '00:02.0');
      expect(vga.description, contains('Iris Xe Graphics'));
      expect(vga.description, contains('[8086:9a49]'));
    });

    test('parses a secondary 3D controller', () {
      final gpu = devices.firstWhere((d) => d.className == '3D controller');
      expect(gpu.busId, '01:00.0');
      expect(gpu.description, contains('GeForce RTX 3070'));
    });

    test('skips audio and network lines entirely', () {
      expect(devices.any((d) => d.description.contains('Audio')), isFalse);
      expect(devices.any((d) => d.description.contains('Ethernet')), isFalse);
    });

    test('rawLine reproduces the original line verbatim, trimmed', () {
      final vga = devices.first;
      expect(
        vga.rawLine,
        '00:02.0 VGA compatible controller [0300]: Intel Corporation '
        'TigerLake-LP GT2 [Iris Xe Graphics] [8086:9a49] (rev 01)',
      );
    });

    test('a blank line does not produce a device or crash the parse', () {
      expect(parseLspciGpuLines('\n\n'), isEmpty);
    });

    test('output with no display adapter at all parses to an empty list', () {
      expect(
        parseLspciGpuLines(
          '02:00.0 Ethernet controller [0200]: Intel Corporation X [8086:15f2]',
        ),
        isEmpty,
      );
    });

    test('tolerates plain (non -nn) lspci lines without the class-id bracket', () {
      final plain = parseLspciGpuLines(
        '00:02.0 VGA compatible controller: Intel Corporation Iris Xe Graphics',
      );
      expect(plain, hasLength(1));
      expect(plain.single.description, 'Intel Corporation Iris Xe Graphics');
    });

    test('a stray carriage return ends the line rather than breaking the parse', () {
      final withCr = parseLspciGpuLines(
        '00:02.0 VGA compatible controller [0300]: Intel [8086:9a49]\r\n'
        '01:00.0 3D controller [0302]: NVIDIA [10de:249d]',
      );
      expect(withCr, hasLength(2));
    });
  });
}
