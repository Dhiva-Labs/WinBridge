import 'hardware_report.dart';

/// Renders [report] as a filled-in copy of
/// `.github/ISSUE_TEMPLATE/hardware_report.md`, heading for heading, so
/// pasting the output straight into a new hardware-report issue needs no
/// reshaping. If that template's headings ever change, this must change with
/// it — nothing enforces the two stay in sync beyond this comment.
///
/// A pure function of [report]: it touches no file, process or clock, which
/// is what makes it possible to test against canned data without a fake
/// process runner in sight.
String renderHardwareReport(HardwareReport report) {
  final buffer = StringBuffer();

  buffer.writeln('**Device** (printer, GPU, USB gadget, ...):');
  buffer.writeln(_deviceLine(report));
  buffer.writeln();

  buffer.writeln(
    '**Ids**: `lsusb` line or `lspci -nn` line for the device:',
  );
  buffer.writeln(_idsBlock(report));
  buffer.writeln();

  buffer.writeln('**Distro / kernel**: (`lsb_release -ds`, `uname -r`)');
  buffer.writeln(report.kernel ?? '(uname unavailable)');
  buffer.writeln();

  buffer.writeln('**What works natively** (no VM involved):');
  for (final line in _nativeLines(report)) {
    buffer.writeln('- $line');
  }
  buffer.writeln();

  buffer.writeln(
    '**What needed the VM** (driver or vendor app installed in the VM, '
    'passthrough used, print bridge, ...):',
  );
  buffer.writeln(
    '_(winbridge cannot detect this — fill in before submitting)_',
  );
  buffer.writeln();

  buffer.writeln("**What doesn't work at all**:");
  buffer.writeln(
    '_(winbridge cannot detect this — fill in before submitting)_',
  );
  buffer.writeln();

  buffer.writeln(
    '**Notes** (exact packages, winbridge commands, gotchas):',
  );
  for (final line in _notesLines(report)) {
    buffer.writeln('- $line');
  }

  return buffer.toString();
}

String _deviceLine(HardwareReport report) {
  if (report.gpus.isEmpty) {
    return report.lspciAvailable
        ? 'no GPU found by lspci'
        : 'unknown (lspci not available on this machine)';
  }
  return report.gpus.map((gpu) => gpu.description).join('; ');
}

String _idsBlock(HardwareReport report) {
  if (report.gpus.isEmpty) {
    return report.lspciAvailable
        ? '(lspci found no VGA or 3D controller)'
        : '(lspci not found — install pciutils to detect the GPU)';
  }
  return report.gpus.map((gpu) => '`${gpu.rawLine}`').join('\n');
}

List<String> _nativeLines(HardwareReport report) {
  final lines = <String>[
    report.vulkanAvailable
        ? 'Vulkan loader present (${report.vulkanLoaderPath ?? 'found'}) — '
            '`run --dxvk` is available'
        : 'no Vulkan loader found — `run --dxvk` is unavailable',
  ];

  final ready = [
    for (final toolchain in report.toolchains)
      if (toolchain.isReady) toolchain.id,
  ];
  if (ready.isNotEmpty) {
    lines.add('toolchains ready to build: ${ready.join(', ')}');
  }

  if (report.wine.resolved) {
    final verified = report.wine.verified ? ', checksum verified' : '';
    lines.add(
      'wine runtime resolved (via ${report.wine.sourceLabel}$verified)',
    );
  }

  return lines;
}

List<String> _notesLines(HardwareReport report) {
  final lines = <String>['winbridge ${report.winbridgeVersion}'];

  lines.add(report.wine.resolved
      ? 'wine: ${report.wine.pinnedVersion} pinned, resolved via '
          '${report.wine.sourceLabel} at ${report.wine.binaryPath}'
      : report.wine.unavailableOnHost
          ? 'wine: ${report.wine.pinnedVersion} pinned, but that build is '
              'x86-64 only and this host is '
              '${report.wine.hostArch ?? 'neither x64 nor arm64'}, so '
              '`winbridge run` is unavailable here (builds are not affected)'
          : 'wine: ${report.wine.pinnedVersion} pinned, not installed yet '
              '(installs automatically on first `winbridge run`)');

  if (report.cpuModel != null) {
    lines.add('cpu: ${report.cpuModel}');
  }

  if (report.prefixes.isEmpty) {
    lines.add('no app prefixes yet');
  } else {
    for (final prefix in report.prefixes) {
      final dxvk = prefix.dxvkVersion == null
          ? 'no DXVK'
          : 'DXVK ${prefix.dxvkVersion} installed (rendering unverified)';
      lines.add('prefix "${prefix.name}": $dxvk');
    }
  }

  final notReady = [
    for (final toolchain in report.toolchains)
      if (!toolchain.isReady) toolchain.id,
  ];
  if (notReady.isNotEmpty) {
    lines.add('toolchains not ready: ${notReady.join(', ')}');
  }

  return lines;
}
