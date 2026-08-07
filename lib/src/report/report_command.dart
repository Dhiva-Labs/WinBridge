import 'package:winbridge/src/cli/command.dart';

import 'report_gatherer.dart';

/// Printed after the report, so a copy-paster always sees where it goes.
const hardwareReportIssueUrl = 'https://github.com/Dhiva-Labs/WinBridge/'
    'issues/new?template=hardware_report.md';

/// `winbridge report` — prints a filled-in hardware-report template for this
/// machine.
///
/// Everything it gathers is local: `uname`, `/proc/cpuinfo`, `lspci`, the
/// managed Wine runtime's own resolution logic, prefix directory listings,
/// and `winbridge doctor`'s toolchain resolution. Nothing is written and
/// nothing is transmitted — the command's whole job ends at printing to
/// stdout, and the URL it prints after the report is something the user
/// pastes into by hand if they choose to. See `docs/distribution.md`.
class ReportCommand extends WinBridgeCommand {
  @override
  String get name => 'report';

  @override
  String get description =>
      'Print a filled-in hardware-report template for this machine.';

  @override
  String get invocation => 'winbridge report';

  @override
  Future<int> run() async {
    final output = context.output;
    final gatherer = ReportGatherer(
      runner: context.processes,
      tools: context.tools,
      config: context.config,
      toolchains: context.registry.toolchains,
    );
    final report = await gatherer.gather();

    output.info(report.toMarkdown());
    output.blank();
    output.info(
      'Nothing above was sent anywhere — it was only printed. Copy it into '
      'a new issue if you want to share it:',
    );
    output.info('  $hardwareReportIssueUrl');
    return 0;
  }
}
