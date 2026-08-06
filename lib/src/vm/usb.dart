import 'package:winbridge/winbridge.dart';

/// One line of `lsusb` output, parsed.
class UsbDevice {
  const UsbDevice({
    required this.bus,
    required this.device,
    required this.vendorId,
    required this.productId,
    required this.name,
  });

  final String bus;
  final String device;

  /// Lowercase 4 hex digits.
  final String vendorId;

  /// Lowercase 4 hex digits.
  final String productId;

  /// Trimmed, and with control characters replaced — see
  /// [sanitizeDeviceName]. `lsusb` omits the descriptor name entirely for some
  /// devices and pads it with trailing whitespace for others; both come out
  /// empty-or-clean here.
  final String name;

  String get id => '$vendorId:$productId';

  /// Linux's own root hubs (vendor `1d6b`, "Linux Foundation") are not
  /// physical devices to pass through — they *are* the host controller — and
  /// a device whose descriptor name says "hub" is a pass-through point with
  /// nothing of its own for a Windows driver to attach to. `vm usb list`
  /// hides both by default.
  bool get isHubLike =>
      vendorId == '1d6b' || name.toLowerCase().contains('hub');

  @override
  String toString() => '$id $name'.trim();
}

final RegExp _lsusbLine = RegExp(
  r'^Bus\s+(\d+)\s+Device\s+(\d+):\s+ID\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})(.*)$',
);

/// C0 controls, DEL, and the C1 range.
final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// A device name is whatever the device says it is: it comes from a USB string
/// descriptor, which the hardware author controls completely. Left as-is it
/// reaches a terminal verbatim, so an `ESC [ 2 J` or a lone `\r` in a
/// descriptor could clear the screen or overwrite the line above — enough to
/// make one device in `vm usb list` look like another, on the very screen a
/// user reads to decide what to hand to the VM. Control characters are
/// replaced before the name goes anywhere.
String sanitizeDeviceName(String raw) =>
    raw.replaceAll(_controlCharacters, '?').trim();

/// Every line terminator, not just `\n`. A bare `\r` counts: Dart's `.` does
/// not match one (it is an ECMAScript line terminator), so a `\r` left inside
/// a line would make `_lsusbLine` fail and drop the device from the listing
/// entirely — a device could hide itself from `vm usb list` by putting one in
/// its descriptor. Splitting on it instead keeps the device visible and ends
/// its name there, which is what a `\r` means on a terminal anyway.
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

/// Parses `lsusb`'s default (no `-v`) output.
///
/// Lines that do not match the `Bus NNN Device NNN: ID vvvv:pppp NAME` shape
/// are skipped rather than failing the whole parse — a blank line or a stray
/// warning on stdout should not take `vm usb list` down with it.
List<UsbDevice> parseLsusb(String output) {
  final devices = <UsbDevice>[];
  for (final line in output.split(_lineBreak)) {
    final match = _lsusbLine.firstMatch(line);
    if (match == null) continue;
    devices.add(UsbDevice(
      bus: match.group(1)!,
      device: match.group(2)!,
      vendorId: match.group(3)!.toLowerCase(),
      productId: match.group(4)!.toLowerCase(),
      name: sanitizeDeviceName(match.group(5)!),
    ));
  }
  return devices;
}

/// A validated `vendor:product` USB id.
///
/// Unlike a `VmConfig` field, this comes from a person typing a command-line
/// argument, but it gets exactly the same treatment: one strict pattern,
/// checked before the value reaches anything that formats it into
/// docker-compose YAML or libvirt XML.
class UsbId {
  const UsbId._(this.vendor, this.product);

  /// Lowercase 4 hex digits.
  final String vendor;

  /// Lowercase 4 hex digits.
  final String product;

  static final RegExp _pattern = RegExp(r'^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$');

  static bool isValid(String value) => _pattern.hasMatch(value);

  /// Throws [UsageFailure] on anything that is not exactly `vvvv:pppp` — this
  /// is command-line input, so a bad value is a usage error like any other
  /// malformed argument, not a build outcome.
  factory UsbId.parse(String value) {
    if (!isValid(value)) {
      throw UsageFailure(
        'invalid usb id: "$value"',
        details: 'expected vendor:product as exactly 4 hex digits each, '
            'e.g. 1462:7c95 — see `winbridge vm usb list`',
      );
    }
    final parts = value.split(':');
    return UsbId._(parts[0].toLowerCase(), parts[1].toLowerCase());
  }

  String get compact => '$vendor:$product';

  @override
  String toString() => compact;
}

/// The configuration `vm usb passthrough` prints for a validated [UsbId]:
/// text for both supported VM backends. Nothing here is ever written to a
/// file on the user's behalf — WinBridge prints it, the user decides.
class UsbPassthroughInstructions {
  const UsbPassthroughInstructions({
    required this.composeSnippet,
    required this.libvirtXml,
    required this.virshCommand,
  });

  final String composeSnippet;
  final String libvirtXml;
  final String virshCommand;
}

UsbPassthroughInstructions usbPassthroughInstructions(UsbId id) {
  final composeSnippet = '''
Add under services.windows.environment in scripts/vm/docker-compose.yml
(merge with any ARGUMENTS value already there, do not replace it):

  ARGUMENTS: "-device usb-host,vendorid=0x${id.vendor},productid=0x${id.product}"

And under services.windows.devices:

  - /dev/bus/usb

Then recreate the container — a running one will not pick this up:

  docker compose up -d --force-recreate''';

  final libvirtXml = '''
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source>
    <vendor id='0x${id.vendor}'/>
    <product id='0x${id.product}'/>
  </source>
</hostdev>''';

  final virshCommand = 'virsh attach-device <domain> '
      'usb-${id.vendor}-${id.product}.xml --live --config';

  return UsbPassthroughInstructions(
    composeSnippet: composeSnippet,
    libvirtXml: libvirtXml,
    virshCommand: virshCommand,
  );
}
