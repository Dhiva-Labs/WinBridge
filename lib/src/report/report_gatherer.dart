import 'dart:io';

import 'package:winbridge/winbridge.dart';

// A deliberate, read-only cross-module import: `lib/src/run/` holds the
// managed Wine runtime, DXVK installer and prefix manager, and this module
// only ever reads their already-computed state (resolution, marker files) —
// never installs, downloads or writes anything through them. Nothing here
// calls `WineRuntime.resolveOrInstall`/`.install` or `DxvkInstaller
// .installInto`. See `docs/DESIGN.md` and the M6 brief for why this one
// cross-module read is sanctioned rather than duplicated.
import '../run/dxvk.dart';
import '../run/prefix.dart';
import '../run/wine_runtime.dart';
import 'hardware_report.dart';
import 'lspci.dart';
import 'redact.dart';

/// Gathers a [HardwareReport] strictly from this machine: local processes
/// (`uname`, `lspci`), local files (`/proc/cpuinfo`, DXVK marker files,
/// prefix directory listings) and pure resolution logic. Nothing here
/// downloads, installs, writes, or reaches the network — see
/// `docs/distribution.md` for the privacy contract `winbridge report` makes.
class ReportGatherer {
  ReportGatherer({
    required this.runner,
    required this.tools,
    required this.config,
    this.toolchains = const [],
    this.cpuInfoPath = '/proc/cpuinfo',
  });

  final ProcessRunner runner;
  final ToolResolver tools;
  final WinBridgeConfig config;

  /// Toolchains to resolve, doctor-equivalent — normally
  /// `context.registry.toolchains`. Taken as a plain list rather than a
  /// `ToolchainRegistry` so a test can hand it `FakeToolchain`s without
  /// reaching into the CLI's composition root.
  final List<Toolchain> toolchains;

  /// Overridable so a test can point this at a fixture instead of the real
  /// `/proc/cpuinfo`.
  final String cpuInfoPath;

  String? get _home => config.environment['HOME'];

  Future<HardwareReport> gather() async {
    final kernel = await _kernel();
    final cpu = _cpuModel();
    final gpuScan = await _gpus();
    final vulkan = VulkanCheck.detect(tools);

    return HardwareReport(
      winbridgeVersion: packageVersion,
      kernel: kernel,
      cpuModel: cpu,
      gpus: gpuScan.devices,
      lspciAvailable: gpuScan.lspciAvailable,
      vulkanAvailable: vulkan.looksAvailable,
      vulkanLoaderPath: _redact(vulkan.loaderPath ?? vulkan.vulkaninfoPath),
      wine: _wineStatus(),
      prefixes: _prefixStatuses(),
      toolchains: _toolchainStatuses(),
    );
  }

  String? _redact(String? path) => path == null ? null : redactHome(path, _home);

  Future<String?> _kernel() async {
    final uname = tools.resolve('uname');
    if (uname == null) return null;
    // Deliberately `-s -r -m -o` only. `-a` (or `-n` alone) would include
    // the machine's network hostname, which this report must never carry.
    final result = await runner.run(uname.path, ['-s', '-r', '-m', '-o']);
    if (!result.ok) return null;
    final line = result.stdout.trim();
    return line.isEmpty ? null : line;
  }

  String? _cpuModel() {
    final file = File(cpuInfoPath);
    if (!file.existsSync()) return null;
    try {
      for (final line in file.readAsLinesSync()) {
        if (!line.startsWith('model name')) continue;
        final colon = line.indexOf(':');
        if (colon < 0) continue;
        final value = line.substring(colon + 1).trim();
        return value.isEmpty ? null : value;
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }

  Future<_GpuScan> _gpus() async {
    final lspci = tools.resolve('lspci');
    if (lspci == null) {
      return const _GpuScan(devices: [], lspciAvailable: false);
    }
    final result = await runner.run(lspci.path, ['-nn']);
    if (!result.ok) {
      return const _GpuScan(devices: [], lspciAvailable: true);
    }
    return _GpuScan(
      devices: parseLspciGpuLines(result.stdout),
      lspciAvailable: true,
    );
  }

  WineStatus _wineStatus() {
    final runtime = WineRuntime(
      config: config,
      tools: tools,
      runner: runner,
      output: Output(),
    );
    // `.resolve()` only inspects paths and stamp files already on disk; it
    // never downloads, installs or writes — see `WineRuntime.resolve` in
    // `lib/src/run/wine_runtime.dart`.
    final resolved = runtime.resolve();
    if (resolved == null) {
      return WineStatus(
        pinnedVersion: pinnedWineBuild.version,
        resolved: false,
      );
    }
    return WineStatus(
      pinnedVersion: pinnedWineBuild.version,
      resolved: true,
      binaryPath: _redact(resolved.binary),
      sourceLabel: resolved.source.label,
      verified: resolved.isVerified,
    );
  }

  List<PrefixStatus> _prefixStatuses() => [
        for (final prefix in PrefixManager(config).list())
          PrefixStatus(
            name: prefix.name,
            // A static read of a marker file inside the prefix — see
            // `DxvkInstaller.installedVersion` — never an install.
            dxvkVersion: DxvkInstaller.installedVersion(prefix),
          ),
      ];

  List<ToolchainStatus> _toolchainStatuses() => [
        for (final toolchain in toolchains)
          ToolchainStatus(
            id: toolchain.id,
            description: toolchain.description,
            requirements: [
              for (final requirement in toolchain.requirements())
                RequirementStatus(
                  label: requirement.candidates.join(' | '),
                  found: tools.resolveAny(requirement.candidates) != null,
                  optional: requirement.optional,
                ),
            ],
          ),
      ];
}

class _GpuScan {
  const _GpuScan({required this.devices, required this.lspciAvailable});

  final List<GpuDevice> devices;
  final bool lspciAvailable;
}
