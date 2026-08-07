import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/toolchains/c.dart';
import 'package:winbridge/src/toolchains/msvc.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support.dart';

void main() {
  const msvc = MsvcToolchain();

  test('identifies itself', () {
    expect(msvc.id, 'msvc');
    expect(msvc.description, contains('MSVC'));
  });

  group('registration', () {
    test('claims C/C++ projects', () {
      expect(msvc.canHandle(fakeProject(ProjectType.c)), isTrue);
    });

    test('claims nothing else', () {
      for (final type in ProjectType.values.where((t) => t != ProjectType.c)) {
        expect(msvc.canHandle(fakeProject(type)), isFalse, reason: type.name);
      }
    });

    test('does not displace the cheap C path', () {
      // Both claim C/C++; registration order decides, and the registry hands
      // back the first. That is what keeps zig/MinGW the default.
      final registry = ToolchainRegistry([
        const CToolchain(),
        const MsvcToolchain(),
      ]);
      expect(registry.forProject(fakeProject(ProjectType.c))!.id, 'c');
      expect(registry.byId('msvc'), isNotNull,
          reason: 'still reachable by name for --toolchain msvc');
    });
  });

  test('requires clang and a linker, resources optional', () {
    final byTool = {for (final r in msvc.requirements()) r.tool: r};
    expect(byTool['clang']!.optional, isFalse);
    expect(byTool['lld-link']!.optional, isFalse);
    expect(byTool['llvm-rc']!.optional, isTrue);
    // Distributions ship only versioned names surprisingly often.
    expect(byTool['lld-link']!.candidates, contains('lld-link-18'));
    expect(byTool['clang']!.candidates, contains('clang-18'));
  });

  group('argument construction', () {
    // This machine has no Windows SDK to link against, so the command
    // WinBridge builds is what can be pinned down here — and it is pinned
    // down exactly.
    final splat = XwinSplat('/splat');
    final arguments = msvcArguments(
      splat: splat,
      sources: ['/proj/main.c'],
      outputExe: '/out/app.exe',
      objectDirectory: '/cache/obj',
      linker: '/usr/bin/lld-link',
      release: true,
      cxx: false,
    );

    test('targets the MSVC ABI through the cl driver', () {
      expect(arguments, contains('--driver-mode=cl'));
      expect(arguments, contains('--target=x86_64-pc-windows-msvc'));
    });

    test('points clang at the linker we resolved', () {
      // Not left to PATH: the binary is often only installed under a
      // versioned name, and clang looks for the bare one.
      expect(arguments, contains('--ld-path=/usr/bin/lld-link'));
    });

    test('adds every SDK include as a system include', () {
      for (final include in splat.includeDirectories) {
        expect(arguments, containsAllInOrder(['/imsvc', include]));
      }
      expect(
        arguments.where((a) => a == '/I'),
        isEmpty,
        reason: "Microsoft's headers are not the user's to fix warnings in",
      );
    });

    test('adds every SDK library path after /link', () {
      final linkIndex = arguments.indexOf('/link');
      expect(linkIndex, greaterThan(0));
      for (final library in splat.libraryDirectories) {
        final index = arguments.indexOf('/libpath:$library');
        expect(index, greaterThan(linkIndex),
            reason: 'libpath must follow /link');
      }
    });

    test('sources come before /link, output after', () {
      expect(arguments.indexOf('/proj/main.c'),
          lessThan(arguments.indexOf('/link')));
      expect(arguments, contains('/out:/out/app.exe'));
    });

    test('optimises for release and not for debug', () {
      expect(arguments, contains('/O2'));
      expect(
        msvcArguments(
          splat: splat,
          sources: const ['/proj/main.c'],
          outputExe: '/out/app.exe',
          objectDirectory: '/cache/obj',
          linker: '/usr/bin/lld-link',
          release: false,
          cxx: false,
        ),
        contains('/Od'),
      );
    });

    test('C++ sources get exception handling', () {
      expect(arguments, isNot(contains('/EHsc')));
      expect(
        msvcArguments(
          splat: splat,
          sources: const ['/proj/main.cpp'],
          outputExe: '/out/app.exe',
          objectDirectory: '/cache/obj',
          linker: '/usr/bin/lld-link',
          release: true,
          cxx: true,
        ),
        contains('/EHsc'),
      );
    });

    test('objects go to the cache, not the project tree', () {
      expect(arguments, contains('/Fo/cache/obj${p.separator}'));
    });

    test('extra arguments land before the sources', () {
      final withExtra = msvcArguments(
        splat: splat,
        sources: const ['/proj/main.c'],
        outputExe: '/out/app.exe',
        objectDirectory: '/cache/obj',
        linker: '/usr/bin/lld-link',
        release: true,
        cxx: false,
        extraArguments: const ['/DFOO=1'],
      );
      expect(withExtra.indexOf('/DFOO=1'),
          lessThan(withExtra.indexOf('/proj/main.c')));
    });
  });

  group('without the Windows SDK', () {
    test('fails with the command that fixes it, and does not download', () async {
      final home = tempDir('home');
      final pathDir = tempDir('path');
      writeExecutable(pathDir, 'clang');
      writeExecutable(pathDir, 'lld-link');
      final config =
          WinBridgeConfig(environment: {'HOME': home, 'PATH': pathDir});
      final runner = RecordingProcessRunner();

      final result = await msvc.build(BuildRequest(
        project: Project(
          root: projectDir({'main.c': 'int main(){return 0;}'}),
          type: ProjectType.c,
          name: 'app',
          evidence: const [
            DetectionEvidence(
                type: ProjectType.c, file: 'main.c', reason: 'C sources'),
          ],
        ),
        outputDirectory: tempDir('out'),
        cacheDirectory: tempDir('cache'),
        runner: runner,
        tools: ToolResolver(config: config),
        output: silentOutput(),
      ));

      expect(result.succeeded, isFalse);
      expect(result.failureMessage, contains('Windows SDK'));
      expect(result.details, contains('doctor --install msvc'));
      expect(runner.calls, isEmpty,
          reason: 'a build must never start a multi-gigabyte download');
    });
  });

  group('splat layout', () {
    test('needs headers and libraries, not just one of them', () {
      final root = tempDir('splat');
      expect(XwinSplat(root).isPresent, isFalse);
      writeFile(p.join(root, 'crt', 'include', 'stdio.h'), '');
      expect(XwinSplat(root).isPresent, isFalse,
          reason: 'a half-finished download must not look usable');
    });

    test('is present once the CRT and SDK directories exist', () {
      final root = tempDir('splat');
      for (final directory in [
        p.join(root, 'crt', 'include'),
        p.join(root, 'crt', 'lib', 'x86_64'),
        p.join(root, 'sdk', 'include', 'ucrt'),
      ]) {
        writeFile(p.join(directory, 'marker'), '');
      }
      expect(XwinSplat(root).isPresent, isTrue);
    });
  });
}
