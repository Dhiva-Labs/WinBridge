import '../bootstrap/components.dart';
import '../bootstrap/installer.dart';
import '../core/config.dart';
import '../core/errors.dart';
import '../core/host_arch.dart';
import '../core/toolchain.dart';
import '../core/version.dart';
import '../run/dxvk.dart';
import '../run/wine_runtime.dart';
import 'command.dart';

/// Reports what WinBridge can and cannot build on this machine.
///
/// Exits 1 when a required tool is missing, so CI can gate on it. Optional
/// requirements are reported but never fail the command.
class DoctorCommand extends WinBridgeCommand {
  DoctorCommand() {
    argParser.addOption(
      'install',
      valueHelp: 'component',
      allowed: [for (final c in installableComponents) c.id],
      help: 'Download and install a component, then exit.\n'
          'Nothing is ever installed without asking; see the\n'
          '"Installable components" section of plain `doctor`.',
    );
  }

  @override
  String get name => 'doctor';

  @override
  String get description => 'Check which toolchains are available.';

  @override
  String get invocation => 'winbridge doctor';

  @override
  Future<int> run() async {
    final output = context.output;
    final tools = context.tools;

    if (argResults!.option('install') case final id?) {
      return _install(id);
    }

    output.info('winbridge $packageVersion');
    output.info(_hostLine(context.config.hostArch));
    output.blank();

    output.info('Tool search path');
    if (tools.searchEntries.isEmpty) {
      output.info('  (empty)');
    }
    for (final entry in tools.searchEntries) {
      output.info('  ${entry.directory}  [${entry.source.label}]');
    }
    output.blank();

    _reportRunRuntime();
    _reportInstallable();

    output.info('Toolchains');
    if (context.registry.isEmpty) {
      output.info('  no adapters registered');
      return 0;
    }

    var missingRequired = 0;
    for (final toolchain in context.registry.toolchains) {
      output.info('  ${toolchain.id} — ${toolchain.description}');
      final requirements = toolchain.requirements();
      if (requirements.isEmpty) {
        output.info('    no external tools required');
      }
      for (final requirement in requirements) {
        final found = tools.resolveAny(requirement.candidates);
        if (found != null) {
          output.info('    ok       ${_label(requirement)}  ${found.path}');
          output.detail('             via ${found.source.label}');
        } else if (requirement.optional) {
          output.info('    absent   ${_label(requirement)}'
              '  ${requirement.reason} (optional)');
        } else {
          missingRequired++;
          output.info('    MISSING  ${_label(requirement)}'
              '  ${requirement.reason}');
        }
      }
    }

    if (missingRequired > 0) {
      output.blank();
      output.info('$missingRequired required '
          '${missingRequired == 1 ? 'tool is' : 'tools are'} missing.');
      return 1;
    }
    return 0;
  }

  /// The Wine runtime behind `winbridge run`. Optional by design — it is never
  /// needed to *build*, and `run` installs it on first use — so a missing one
  /// is reported without failing the command.
  void _reportRunRuntime() {
    final output = context.output;
    final runtime = WineRuntime(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    );

    output.info('Runtime for `winbridge run`');
    final resolved = runtime.resolve();
    if (resolved == null && !runtime.managedBuildSupported) {
      // Not "absent": nothing WinBridge can install here would fix it. Still
      // optional — building never needs Wine — so it does not fail the command.
      final arch = context.config.hostArch;
      output.info('  n/a      wine          unavailable on '
          '${arch == null ? 'this CPU' : arch.slug}: the managed build '
          '(${pinnedWineBuild.name}) is x86-64 only (optional)');
      output.info('                         `run`, `package` and `prefix tricks` '
          'need Wine; set ${WinBridgeConfig.wineVariable} to a Wine that runs '
          'x86-64 Windows programs to use your own');
    } else if (resolved == null) {
      output.info('  absent   wine          ${pinnedWineBuild.name}, installed '
          'automatically on first `winbridge run` (optional)');
      final target = runtime.managedDirectory;
      if (target != null) output.detail('           would install into $target');
    } else {
      output.info('  ok       wine          ${resolved.binary}');
      output.detail('           via ${resolved.source.label}'
          '${resolved.isVerified ? ', checksum verified' : ''}');
    }

    // Vulkan is optional: only DXVK needs it, and only for Direct3D apps.
    // Reported as loader-present or not — which graphics hardware is in the
    // machine, and whose driver is in use, is not WinBridge's to guess at.
    final vulkan = VulkanCheck.detect(
      context.tools,
      arch: context.config.hostArch,
    );
    if (vulkan.looksAvailable) {
      final found = vulkan.loaderPath ?? vulkan.vulkaninfoPath;
      output.info('  ok       vulkan        $found — `run --dxvk` available');
    } else {
      output.info('  absent   vulkan        no Vulkan loader found; '
          '`run --dxvk` needs one (optional)');
    }
    output.blank();
  }

  /// `doctor --install <id>`.
  Future<int> _install(String id) async {
    final component = findComponent(id);
    if (component == null) {
      throw UsageFailure(
        'unknown component: $id',
        details: 'available: '
            '${installableComponents.map((c) => c.id).join(', ')}',
      );
    }

    final installer = ComponentInstaller(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: context.output,
    );
    if (installer.unavailableReason(component) case final reason?) {
      throw reason;
    }
    if (installer.isComplete(component)) {
      context.output.info('${component.id} is already installed.');
      return 0;
    }
    await installer.install(component);
    return 0;
  }

  /// What `--install` can fetch, and how big each one is, so the choice is
  /// informed before anything starts downloading.
  void _reportInstallable() {
    final output = context.output;
    final installer = ComponentInstaller(
      config: context.config,
      tools: context.tools,
      runner: context.processes,
      output: output,
    );

    final arch = context.config.hostArch;
    output.info('Installable components  (winbridge doctor --install <name>)');
    for (final component in installableComponents) {
      // "system" matters: a tool already on the search path works fine, it is
      // simply not one WinBridge downloaded and can vouch for.
      final unavailable = installer.unavailableReason(component) != null;
      final note = !unavailable
          ? ''
          : component.assetFor(arch) == null
              ? ' (no download for this CPU)'
              : ' (needs Wine, unavailable on this host)';
      final state = unavailable
          ? 'n/a    '
          : installer.isComplete(component)
              ? 'managed'
              : installer.isInstalled(component)
                  ? 'partial'
                  : component.probeBinary != null &&
                          context.tools.resolve(component.probeBinary!) != null
                      ? 'system '
                      : 'absent ';
      output.info('  $state  ${component.id.padRight(6)} '
          '${component.downloadSizeFor(arch).padRight(14)} '
          '${component.summary}$note');
    }
    output.blank();
  }

  /// `Host: arm64 (aarch64)` — the CPU the downloads and the Wine decision are
  /// made for, so a report from an arm64 machine says so at the top.
  static String _hostLine(HostArch? arch) => arch == null
      ? 'Host: unsupported CPU (managed downloads are x86-64 and arm64 only)'
      : 'Host: linux ${arch.slug} (${arch.machine})';

  String _label(ToolRequirement requirement) =>
      requirement.candidates.join(' | ').padRight(12);
}
