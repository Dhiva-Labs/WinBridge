import '../core/registry.dart';
import '../core/toolchain.dart';

/// The composition root for toolchain adapters.
///
/// This is the one place the CLI is allowed to import `lib/src/toolchains/` or
/// `lib/src/vm/`. Landing an adapter means adding its constructor to this list
/// and nothing else; order matters, because the first toolchain that claims a
/// project builds it.
List<Toolchain> registeredToolchains() => const [];

ToolchainRegistry defaultRegistry() =>
    ToolchainRegistry(registeredToolchains());
