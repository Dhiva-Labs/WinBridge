/// The one sanctioned export from this module: the CLI wiring point.
///
/// Per `docs/DESIGN.md`, `lib/src/cli/` is driven by feature modules, never
/// the reverse — the same rule `lib/src/vm/vm_command.dart` and
/// `lib/src/desktop/desktop_command.dart` follow. The composition root wires
/// this in with one line, alongside the other `addCommand` calls in
/// `lib/src/cli/runner.dart`'s constructor:
///
/// ```dart
/// addCommand(ReportCommand());
/// ```
library;

export 'report_command.dart' show ReportCommand, hardwareReportIssueUrl;
