import '../core/artifact.dart';
import '../core/registry.dart';
import '../core/toolchain.dart';
import '../pe/pe_verifier.dart';
import '../toolchains/c.dart';
import '../toolchains/dotnet.dart';
import '../toolchains/go.dart';
import '../toolchains/msvc.dart';
import '../toolchains/rust.dart';
import '../vm/vm.dart';

/// The composition root for toolchain adapters.
///
/// This is the one place the CLI is allowed to import `lib/src/toolchains/` or
/// `lib/src/vm/`. Landing an adapter means adding its constructor to this list
/// and nothing else; order matters, because the first toolchain that claims a
/// project builds it.
List<Toolchain> registeredToolchains() => [
      const GoToolchain(),
      const RustToolchain(),
      const DotnetToolchain(),
      const CToolchain(),
      // After CToolchain on purpose: the cheap MinGW path stays the default
      // for C/C++, and `--toolchain msvc` is what reaches this one.
      const MsvcToolchain(),
      FlutterVmToolchain(),
    ];

ToolchainRegistry defaultRegistry() =>
    ToolchainRegistry(registeredToolchains());

/// Artifact checks composed by the CLI and run over every build's output —
/// a toolchain never vouches for its own binary. See docs/DESIGN.md's
/// "extension seams" section.
List<ArtifactVerifier> defaultVerifiers() => const [PeVerifier()];
