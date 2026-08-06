import 'package:test/test.dart';
import 'package:winbridge/src/vm/vm.dart';
import 'package:winbridge/winbridge.dart';

// A literal trailing space, spliced in by interpolation rather than typed at
// the end of a source line — an editor, formatter or pre-commit hook that
// trims trailing whitespace would otherwise silently delete the exact thing
// this fixture needs to test.
const _trailingSpace = ' ';

// A captured lsusb block: the two real device lines from the task brief (one
// with trailing whitespace, one without), two Linux Foundation root hubs, a
// real (non-1d6b) hub whose name says so, and two flavors of empty name —
// trailing-space-only and nothing at all after the id. Real lsusb output has
// all of these.
const _lsusbSample = '''
Bus 002 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
Bus 001 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub
Bus 001 Device 002: ID 0451:8025 Texas Instruments, Inc. TUSB8020B 2-Port Hub
Bus 001 Device 003: ID 1462:7c95 Micro Star International MYSTIC LIGHT$_trailingSpace
Bus 001 Device 004: ID 0e8d:0616 MediaTek Inc. Wireless_Device
Bus 003 Device 002: ID 8087:0aaa$_trailingSpace
Bus 003 Device 003: ID 8087:0032''';

void main() {
  group('parseLsusb', () {
    final devices = parseLsusb(_lsusbSample);

    test('parses every line, including the empty-name ones', () {
      expect(devices, hasLength(7));
    });

    test('tolerates a trailing space in the name', () {
      final msi = devices.firstWhere((d) => d.id == '1462:7c95');
      expect(msi.name, 'Micro Star International MYSTIC LIGHT');
      expect(msi.bus, '001');
      expect(msi.device, '003');
    });

    test('parses a name with no trailing space too', () {
      final mediatek = devices.firstWhere((d) => d.id == '0e8d:0616');
      expect(mediatek.name, 'MediaTek Inc. Wireless_Device');
    });

    test('an id with only trailing whitespace after it has an empty name', () {
      final device = devices.firstWhere((d) => d.id == '8087:0aaa');
      expect(device.name, isEmpty);
    });

    test('an id with nothing at all after it has an empty name', () {
      final device = devices.firstWhere((d) => d.id == '8087:0032');
      expect(device.name, isEmpty);
    });

    test('vendor and product ids are lowercased', () {
      final msi = devices.firstWhere((d) => d.bus == '001' && d.device == '003');
      expect(msi.vendorId, '1462');
      expect(msi.productId, '7c95');
    });

    test('skips lines that are not lsusb device lines', () {
      final devices = parseLsusb('some warning on stdout\n\n$_lsusbSample');
      expect(devices, hasLength(7));
    });
  });

  // A device name is a USB string descriptor: the hardware author writes it,
  // and `vm usb list` is the screen a user reads to decide what to hand to the
  // VM. Neither fake ids nor terminal escapes in a name may affect it.
  group('a device that lies about itself', () {
    test('a fake "ID vvvv:pppp" in the name does not become the id', () {
      final device = parseLsusb(
        'Bus 001 Device 005: ID 1234:5678 Evil ID dead:beef Hub',
      ).single;

      expect(device.vendorId, '1234');
      expect(device.productId, '5678');
      expect(device.name, 'Evil ID dead:beef Hub');
    });

    test('terminal escapes in a name are neutralised', () {
      final device = parseLsusb(
        'Bus 001 Device 006: ID aaaa:bbbb Ev\u001b[2Jil\u0007 Device',
      ).single;

      expect(device.name, isNot(contains('\u001b')));
      expect(device.name, isNot(contains('\u0007')));
      expect(device.name, 'Ev?[2Jil? Device');
    });

    test('a carriage return ends the name instead of hiding the device', () {
      final devices = parseLsusb(
        'Bus 001 Device 007: ID cccc:dddd real\rfake trusted device',
      );

      // The device must still be listed — dropping the line would let a
      // device stay out of `vm usb list` by putting a \r in its descriptor.
      expect(devices, hasLength(1));
      expect(devices.single.id, 'cccc:dddd');
      expect(devices.single.name, 'real');
    });

    test('CRLF output parses the same as LF', () {
      final crlf = parseLsusb(
        'Bus 001 Device 003: ID 1462:7c95 MSI Thing\r\n'
        'Bus 001 Device 004: ID 0e8d:0616 MediaTek\r\n',
      );
      expect(crlf.map((d) => d.id), ['1462:7c95', '0e8d:0616']);
      expect(crlf.first.name, 'MSI Thing');
    });

    test('sanitizeDeviceName leaves ordinary names alone', () {
      expect(
        sanitizeDeviceName(' Micro Star International MYSTIC LIGHT '),
        'Micro Star International MYSTIC LIGHT',
      );
      expect(sanitizeDeviceName('Wireless_Device'), 'Wireless_Device');
    });
  });

  group('UsbDevice.isHubLike', () {
    final devices = parseLsusb(_lsusbSample);

    test('both 1d6b root hubs are hub-like', () {
      expect(devices.where((d) => d.vendorId == '1d6b'), hasLength(2));
      for (final hub in devices.where((d) => d.vendorId == '1d6b')) {
        expect(hub.isHubLike, isTrue);
      }
    });

    test('a non-1d6b device whose name says Hub is hub-like too', () {
      final tiHub = devices.firstWhere((d) => d.id == '0451:8025');
      expect(tiHub.isHubLike, isTrue);
    });

    test('ordinary devices are not hub-like', () {
      expect(devices.firstWhere((d) => d.id == '1462:7c95').isHubLike, isFalse);
      expect(devices.firstWhere((d) => d.id == '0e8d:0616').isHubLike, isFalse);
    });

    test('list --all-equivalent filtering keeps exactly the non-hub devices', () {
      final kept = devices.where((d) => !d.isHubLike).map((d) => d.id).toSet();
      expect(kept, {'1462:7c95', '0e8d:0616', '8087:0aaa', '8087:0032'});
    });
  });

  group('UsbId', () {
    for (final good in ['1462:7c95', '0E8D:0616', '0e8d:0616', 'FFFF:0000']) {
      test('accepts "$good"', () {
        expect(UsbId.isValid(good), isTrue);
        final id = UsbId.parse(good);
        expect(id.compact, good.toLowerCase());
      });
    }

    for (final bad in [
      '12345:0616',
      '0e8d:061',
      '0e8d:woot',
      r'$(x):0616',
      '0e8d:0616 extra',
      '0e8d0616',
      '0e8d:',
      ':0616',
      '',
      ' 0e8d:0616',
      '0e8d:0616\n',
      '0e8d:0616;calc',
    ]) {
      test('rejects "$bad"', () {
        expect(UsbId.isValid(bad), isFalse);
        expect(
          () => UsbId.parse(bad),
          throwsA(isA<UsageFailure>()
              .having((e) => e.message, 'message', contains('invalid usb id'))
              .having((e) => e.exitCode, 'exitCode', 2)),
        );
      });
    }
  });

  group('usbPassthroughInstructions', () {
    final id = UsbId.parse('1462:7c95');
    final instructions = usbPassthroughInstructions(id);

    test('compose snippet carries the exact vendorid/productid pair', () {
      expect(
        instructions.composeSnippet,
        contains('ARGUMENTS: "-device usb-host,vendorid=0x1462,productid=0x7c95"'),
      );
      expect(instructions.composeSnippet, contains('/dev/bus/usb'));
      expect(instructions.composeSnippet, contains('docker compose up -d --force-recreate'));
    });

    test('libvirt XML is a well-formed hostdev fragment', () {
      expect(instructions.libvirtXml, contains("<hostdev mode='subsystem' type='usb'"));
      expect(instructions.libvirtXml, contains("<vendor id='0x1462'/>"));
      expect(instructions.libvirtXml, contains("<product id='0x7c95'/>"));
      expect('<'.allMatches(instructions.libvirtXml).length,
          '>'.allMatches(instructions.libvirtXml).length);
    });

    test('the virsh command is a live+persistent attach', () {
      expect(instructions.virshCommand, startsWith('virsh attach-device'));
      expect(instructions.virshCommand, contains('--live'));
      expect(instructions.virshCommand, contains('--config'));
    });

    test('is a pure function of the id — same id, same output', () {
      final again = usbPassthroughInstructions(UsbId.parse('1462:7C95'));
      expect(again.composeSnippet, instructions.composeSnippet);
      expect(again.libvirtXml, instructions.libvirtXml);
      expect(again.virshCommand, instructions.virshCommand);
    });

    test('different ids never share emitted vendor/product hex', () {
      final other = usbPassthroughInstructions(UsbId.parse('0e8d:0616'));
      expect(other.composeSnippet, isNot(contains('1462')));
      expect(other.composeSnippet, contains('0e8d'));
      expect(other.composeSnippet, contains('0616'));
    });
  });

  group('command wiring', () {
    test('vm usb is registered under vm with list and passthrough', () {
      final vm = VmCommand();
      final usb = vm.subcommands['usb'];
      expect(usb, isNotNull);
      expect(usb, isA<VmUsbCommand>());
      expect(usb!.subcommands.keys, containsAll(['list', 'passthrough']));
      expect(usb.subcommands['list'], isA<VmUsbListCommand>());
      expect(usb.subcommands['passthrough'], isA<VmUsbPassthroughCommand>());
    });

    test('vm still has status and doctor alongside usb', () {
      final vm = VmCommand();
      expect(vm.subcommands.keys, containsAll(['status', 'doctor', 'usb']));
    });
  });
}
