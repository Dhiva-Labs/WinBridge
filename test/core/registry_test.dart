import 'package:test/test.dart';
import 'package:winbridge/src/cli/toolchain_setup.dart';
import 'package:winbridge/winbridge.dart';

import '../support/toolchains.dart';

void main() {
  final go = FakeToolchain(id: 'go', handles: {ProjectType.go});
  final zig = FakeToolchain(id: 'zig-cc', handles: {ProjectType.c});
  final mingw = FakeToolchain(id: 'mingw', handles: {ProjectType.c});

  test('is empty by default', () {
    expect(ToolchainRegistry().isEmpty, isTrue);
  });

  test('keeps registration order', () {
    final registry = ToolchainRegistry([go, zig, mingw]);
    expect(registry.toolchains.map((t) => t.id), ['go', 'zig-cc', 'mingw']);
  });

  test('routes a project to the first toolchain that claims it', () {
    final registry = ToolchainRegistry([go, zig, mingw]);
    expect(registry.forProject(fakeProject(ProjectType.c))!.id, 'zig-cc');
    expect(registry.forProject(fakeProject(ProjectType.go))!.id, 'go');
  });

  test('reports every toolchain that claims a project', () {
    final registry = ToolchainRegistry([go, zig, mingw]);
    expect(registry.allFor(fakeProject(ProjectType.c)).map((t) => t.id),
        ['zig-cc', 'mingw']);
  });

  test('returns null when nothing claims the project', () {
    final registry = ToolchainRegistry([go]);
    expect(registry.forProject(fakeProject(ProjectType.rust)), isNull);
    expect(registry.allFor(fakeProject(ProjectType.rust)), isEmpty);
  });

  test('looks up by id', () {
    final registry = ToolchainRegistry([go, zig]);
    expect(registry.byId('zig-cc'), same(zig));
    expect(registry.byId('nope'), isNull);
  });

  test('refuses a duplicate id', () {
    final registry = ToolchainRegistry([go]);
    expect(
      () => registry.register(FakeToolchain(id: 'go', handles: const {})),
      throwsStateError,
    );
  });

  test('the shipped registry builds, whatever adapters are wired in', () {
    // Guards the composition root: two adapters landing with the same id would
    // otherwise only blow up at runtime, on the user's machine.
    expect(defaultRegistry, returnsNormally);
    for (final toolchain in defaultRegistry().toolchains) {
      expect(toolchain.id, isNotEmpty);
      expect(toolchain.description, isNotEmpty);
      expect(toolchain.requirements, returnsNormally);
    }
  });
}
