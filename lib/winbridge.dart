/// The surface toolchain adapters and the VM module build against.
///
/// `lib/src/cli/` is deliberately not exported: adapters are driven by the CLI,
/// never the other way around.
library;

export 'src/core/artifact.dart';
export 'src/core/build.dart';
export 'src/core/config.dart';
export 'src/core/errors.dart';
export 'src/core/host_arch.dart';
export 'src/core/output.dart';
export 'src/core/paths.dart';
export 'src/core/process_runner.dart';
export 'src/core/registry.dart';
export 'src/core/tool_resolver.dart';
export 'src/core/toolchain.dart';
export 'src/core/version.dart';
export 'src/detect/detector.dart';
export 'src/detect/project.dart';
export 'src/detect/pubspec.dart';
