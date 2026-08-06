import '../core/toolchain.dart';
import '../core/version.dart';
import 'command.dart';

/// Reports what WinBridge can and cannot build on this machine.
///
/// Exits 1 when a required tool is missing, so CI can gate on it. Optional
/// requirements are reported but never fail the command.
class DoctorCommand extends WinBridgeCommand {
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

    output.info('winbridge $packageVersion');
    output.blank();

    output.info('Tool search path');
    if (tools.searchEntries.isEmpty) {
      output.info('  (empty)');
    }
    for (final entry in tools.searchEntries) {
      output.info('  ${entry.directory}  [${entry.source.label}]');
    }
    output.blank();

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

  String _label(ToolRequirement requirement) =>
      requirement.candidates.join(' | ').padRight(12);
}
