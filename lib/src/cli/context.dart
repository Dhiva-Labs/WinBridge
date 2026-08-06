import '../core/artifact.dart';
import '../core/config.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/registry.dart';
import '../core/tool_resolver.dart';
import '../detect/detector.dart';

/// The wiring shared by every command: one config, one resolver, one process
/// runner, one output. Commands take what they need from here instead of
/// constructing collaborators, which is also how tests substitute fakes.
class WinBridgeContext {
  WinBridgeContext({
    required this.registry,
    WinBridgeConfig? config,
    bool verbose = false,
    StringSink? out,
    StringSink? err,
    this.verifiers = const [],
  })  : config = config ?? WinBridgeConfig(),
        output = Output(verbose: verbose, out: out, err: err);

  final ToolchainRegistry registry;
  final WinBridgeConfig config;
  final Output output;

  /// Extra artifact checks composed by the CLI, such as the PE32+ header
  /// reader. Adapters never see these.
  final List<ArtifactVerifier> verifiers;

  final ProjectDetector detector = const ProjectDetector();

  late final ToolResolver tools = ToolResolver(config: config);

  late final ProcessRunner processes = ProcessRunner(output: output);
}
