import '../detect/project.dart';
import 'toolchain.dart';

/// The set of toolchains this CLI knows about.
///
/// Injectable on purpose: tests build registries holding fakes, and the real
/// wiring lives in one place (`lib/src/cli/toolchain_setup.dart`) so adding an
/// adapter is a one-line change that cannot accidentally reach into the rest of
/// the CLI.
class ToolchainRegistry {
  ToolchainRegistry([Iterable<Toolchain> toolchains = const []]) {
    toolchains.forEach(register);
  }

  final List<Toolchain> _toolchains = [];

  void register(Toolchain toolchain) {
    if (byId(toolchain.id) != null) {
      throw StateError('duplicate toolchain id: ${toolchain.id}');
    }
    _toolchains.add(toolchain);
  }

  /// Registration order, which is also the order [forProject] considers.
  List<Toolchain> get toolchains => List.unmodifiable(_toolchains);

  bool get isEmpty => _toolchains.isEmpty;

  Toolchain? byId(String id) {
    for (final toolchain in _toolchains) {
      if (toolchain.id == id) return toolchain;
    }
    return null;
  }

  /// The toolchain that will build [project]: the first registered one that
  /// claims it.
  Toolchain? forProject(Project project) {
    for (final toolchain in _toolchains) {
      if (toolchain.canHandle(project)) return toolchain;
    }
    return null;
  }

  /// Every toolchain that claims [project]. Only the first is used; the rest
  /// are shown by `detect` as alternatives.
  List<Toolchain> allFor(Project project) =>
      [for (final t in _toolchains) if (t.canHandle(project)) t];
}
