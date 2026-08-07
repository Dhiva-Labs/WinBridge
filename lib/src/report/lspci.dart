/// One `lspci -nn` line describing a graphics adapter.
///
/// Only the two classes that are actually a GPU: "VGA compatible controller"
/// (the primary display adapter) and "3D controller" (a secondary GPU with no
/// display output of its own — common on hybrid-graphics laptops). Every
/// other class on the bus — network, audio, bridges, storage — is not a
/// graphics device and [parseLspciGpuLines] leaves it out.
class GpuDevice {
  const GpuDevice({
    required this.busId,
    required this.className,
    required this.description,
    required this.rawLine,
  });

  /// e.g. `01:00.0`.
  final String busId;

  /// `VGA compatible controller` or `3D controller`.
  final String className;

  /// Everything after the class, e.g. `NVIDIA Corporation GA104M [GeForce
  /// RTX 3070 Mobile / Max-Q] [10de:249d] (rev a1)`.
  final String description;

  /// The whole matched line, trimmed but otherwise verbatim — this is what
  /// the hardware-report template's "Ids" field asks a contributor to paste,
  /// so the report reproduces it exactly rather than reassembling it from
  /// the parsed parts.
  final String rawLine;

  @override
  String toString() => rawLine;
}

/// `<bus> <class>[ [xxxx]]: <description>`, with or without the numeric
/// class-id bracket `-nn` adds. The bracket is optional in the pattern so a
/// plain (non-`-nn`) `lspci` line still parses, even though `winbridge
/// report` always asks for `-nn`.
final RegExp _lspciGpuLine = RegExp(
  r'^(\S+)\s+(VGA compatible controller|3D controller)(?:\s+\[\w{4}\])?:'
  r'\s*(.+)$',
);

/// Every line terminator, not just `\n` — matches `parseLsusb`'s reasoning in
/// `lib/src/vm/usb.dart`: a stray `\r` must not merge two lines or drop one.
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

/// Parses `lspci -nn` output for its VGA/3D controller lines only.
///
/// Lines that do not match are skipped rather than failing the whole parse —
/// a blank line, a warning, or any other device class on the bus should not
/// take `winbridge report` down with it.
List<GpuDevice> parseLspciGpuLines(String output) {
  final devices = <GpuDevice>[];
  for (final line in output.split(_lineBreak)) {
    final trimmed = line.trim();
    final match = _lspciGpuLine.firstMatch(trimmed);
    if (match == null) continue;
    devices.add(GpuDevice(
      busId: match.group(1)!,
      className: match.group(2)!,
      description: match.group(3)!.trim(),
      rawLine: trimmed,
    ));
  }
  return devices;
}
