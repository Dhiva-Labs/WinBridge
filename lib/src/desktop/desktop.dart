/// The one sanctioned export from this module: the CLI wiring point.
///
/// Per `docs/DESIGN.md`, `lib/src/cli/` is driven by feature modules, never
/// the reverse — the same rule `lib/src/vm/vm_command.dart` follows for `vm`.
/// The composition root wires this in with one line:
///
/// ```dart
/// addCommand(DesktopCommand());
/// ```
library;

export 'desktop_command.dart' show DesktopCommand;
