import 'lspci.dart';
import 'report_markdown.dart';

/// Everything `winbridge report` could determine about this machine, gathered
/// once by `ReportGatherer.gather()` and otherwise inert: rendering it to
/// markdown ([toMarkdown]) is a pure function of this data, which is what
/// makes the golden-output tests possible without spawning a real process
/// every time an assertion runs.
///
/// Every string field here has already had any path under the reporter's
/// home directory redacted to `~` — see `redact.dart` — so nothing further
/// upstream needs to know that rule exists.
class HardwareReport {
  const HardwareReport({
    required this.winbridgeVersion,
    required this.kernel,
    required this.cpuModel,
    required this.gpus,
    required this.lspciAvailable,
    required this.vulkanAvailable,
    required this.vulkanLoaderPath,
    required this.wine,
    required this.prefixes,
    required this.toolchains,
  });

  final String winbridgeVersion;

  /// `uname -s -r -m -o` output, e.g. `Linux 6.8.0-49-generic x86_64
  /// GNU/Linux` — deliberately never `-a`/`-n`, which would include the
  /// machine's network hostname. Null when `uname` could not be run.
  final String? kernel;

  /// The first `model name` line of `/proc/cpuinfo`. Null when it could not
  /// be read.
  final String? cpuModel;

  final List<GpuDevice> gpus;

  /// Whether `lspci` itself was found — distinct from [gpus] being empty,
  /// which could otherwise mean either "no lspci" or "lspci ran and found
  /// no display adapter".
  final bool lspciAvailable;

  final bool vulkanAvailable;

  /// Path to whichever of the Vulkan loader or `vulkaninfo` was found, for
  /// display only. Already redacted.
  final String? vulkanLoaderPath;

  final WineStatus wine;
  final List<PrefixStatus> prefixes;
  final List<ToolchainStatus> toolchains;

  /// Renders this report as a filled-in copy of
  /// `.github/ISSUE_TEMPLATE/hardware_report.md`, heading for heading.
  String toMarkdown() => renderHardwareReport(this);
}

/// What `winbridge report` knows about the managed Wine runtime.
class WineStatus {
  const WineStatus({
    required this.pinnedVersion,
    required this.resolved,
    this.binaryPath,
    this.sourceLabel,
    this.verified = false,
    this.unavailableOnHost = false,
    this.hostArch,
  });

  /// The version WinBridge is pinned to, regardless of whether it is
  /// installed yet — see `lib/src/run/wine_runtime.dart`'s `pinnedWineBuild`.
  final String pinnedVersion;

  /// Whether `WineRuntime.resolve()` found a usable `wine`, by any of its
  /// three resolution paths.
  final bool resolved;

  /// Already redacted. Null when [resolved] is false.
  final String? binaryPath;

  /// `WineSource.label` for whichever path resolved it — never a value that
  /// could itself be sensitive, only the name of the mechanism
  /// (`WINBRIDGE_WINE`, `managed runtime`, or `PATH`).
  final String? sourceLabel;

  /// Whether WinBridge itself verified these bytes against the pin — true
  /// only for the managed runtime; see `WineSource` for why the other two
  /// paths are trusted on the user's say-so instead.
  final bool verified;

  /// True when this machine's CPU cannot run the pinned Wine at all (it is an
  /// x86-64 build), so there is nothing to install and `winbridge run` stops
  /// with an explanation. Distinct from "not installed yet", which a first run
  /// fixes by itself.
  final bool unavailableOnHost;

  /// The host architecture's name (`arm64`), or null when it is neither x64
  /// nor arm64. Only meaningful alongside [unavailableOnHost].
  final String? hostArch;
}

/// One app prefix and whatever DXVK state it carries.
class PrefixStatus {
  const PrefixStatus({required this.name, required this.dxvkVersion});

  /// The app name a prefix is keyed by — never its filesystem path, which
  /// would carry the reporter's home directory.
  final String name;

  /// Null when the prefix has no DXVK installed. Its presence only ever
  /// means the DLLs were copied in, never that Direct3D rendering through
  /// them was verified to work — see `COMPATIBILITY.md`.
  final String? dxvkVersion;
}

/// One registered toolchain, resolved the same way `winbridge doctor` does.
class ToolchainStatus {
  const ToolchainStatus({
    required this.id,
    required this.description,
    required this.requirements,
  });

  final String id;
  final String description;
  final List<RequirementStatus> requirements;

  /// Whether every non-optional requirement resolved — the same rule
  /// `winbridge doctor` uses to decide its exit code.
  bool get isReady => requirements.every((r) => r.found || r.optional);
}

/// One `ToolRequirement`, resolved.
class RequirementStatus {
  const RequirementStatus({
    required this.label,
    required this.found,
    required this.optional,
  });

  /// The requirement's candidates joined for display, e.g. `zig |
  /// x86_64-w64-mingw32-gcc`.
  final String label;

  final bool found;
  final bool optional;
}
