/// Surface for the M2 Windows VM build path.
///
/// Two things need wiring outside this directory, and neither is done here —
/// `lib/src/vm/` is not allowed to import `lib/src/cli/toolchain_setup.dart`
/// or `lib/src/cli/runner.dart`, only the other way around:
///
///  * [FlutterVmToolchain] belongs in `toolchain_setup.dart`'s
///    `registeredToolchains()`, last, so a project a native cross-compiler
///    already handles never touches the network.
///  * [VmCommand] belongs alongside `BuildCommand`/`DetectCommand`/
///    `DoctorCommand` in `WinBridgeRunner`'s constructor, via `addCommand`.
library;

export 'flutter_vm_toolchain.dart';
export 'remote_command.dart';
export 'vm_command.dart';
export 'vm_config.dart';
export 'vm_transport.dart';
