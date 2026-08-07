import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/dxvk.dart';
import 'package:winbridge/src/run/prefix.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late String pathDir;
  late AppPrefix prefix;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    prefix = AppPrefix(name: 'game', path: p.join(tempDir('prefixes'), 'game'));
  });

  WinBridgeConfig configWith({String? dllOverrides}) =>
      WinBridgeConfig(environment: {
        'HOME': home,
        'PATH': pathDir,
        'WINEDLLOVERRIDES': ?dllOverrides,
      });

  DxvkInstaller installerWith({ProcessRunner? runner}) {
    final config = configWith();
    return DxvkInstaller(
      config: config,
      tools: ToolResolver(config: config),
      runner: runner ?? RecordingProcessRunner(),
      output: silentOutput(),
    );
  }

  /// A cached DXVK install, as a verified download would leave it.
  String cacheDxvk() {
    final dir =
        p.join(home, '.cache', 'winbridge', 'runtimes', pinnedDxvk.name);
    for (final arch in ['x64', 'x32']) {
      for (final dll in dxvkDlls) {
        writeFile(p.join(dir, arch, '$dll.dll'), '$arch-$dll-bytes');
      }
    }
    writeFile(
      p.join(dir, '.winbridge-verified'),
      '${pinnedDxvk.name}\n${pinnedDxvk.sha256}\n',
    );
    return dir;
  }

  void createWindowsDirs({bool syswow64 = true}) {
    Directory(p.join(prefix.path, 'drive_c', 'windows', 'system32'))
        .createSync(recursive: true);
    if (syswow64) {
      Directory(p.join(prefix.path, 'drive_c', 'windows', 'syswow64'))
          .createSync(recursive: true);
    }
  }

  test('the pin names an exact release with a checksum', () {
    expect(pinnedDxvk.version, '3.0.2');
    expect(pinnedDxvk.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(pinnedDxvk.url, startsWith('https://github.com/doitsujin/dxvk/'));
    expect(pinnedDxvk.url, contains(pinnedDxvk.version));
    expect(pinnedDxvk.archiveTopLevel, pinnedDxvk.name);
  });

  group('dll overrides', () {
    test('names every dll DXVK provides, as native', () {
      expect(dxvkDllOverrides(), 'd3d8,d3d9,d3d10core,d3d11,dxgi=n');
    });

    test('covers exactly the dlls that get installed', () {
      final overridden =
          dxvkDllOverrides().split('=').first.split(',').toSet();
      expect(overridden, dxvkDlls.toSet());
    });

    test("a user's own overrides go last, so theirs win", () {
      // Wine reads the list left to right and a later entry wins, so someone
      // debugging can always override us.
      expect(
        dxvkDllOverrides(existing: 'd3d11=b'),
        'd3d8,d3d9,d3d10core,d3d11,dxgi=n;d3d11=b',
      );
    });

    test('an empty or blank existing value is ignored', () {
      expect(dxvkDllOverrides(existing: ''), dxvkDllOverrides());
      expect(dxvkDllOverrides(existing: '   '), dxvkDllOverrides());
      expect(dxvkDllOverrides(existing: null), dxvkDllOverrides());
    });
  });

  group('installing into a prefix', () {
    test('copies x64 to system32 and x32 to syswow64', () async {
      cacheDxvk();
      createWindowsDirs();

      await installerWith().installInto(prefix);

      for (final dll in dxvkDlls) {
        final x64 = File(p.join(
            prefix.path, 'drive_c', 'windows', 'system32', '$dll.dll'));
        final x32 = File(p.join(
            prefix.path, 'drive_c', 'windows', 'syswow64', '$dll.dll'));
        expect(x64.existsSync(), isTrue, reason: 'system32/$dll.dll');
        expect(x64.readAsStringSync(), 'x64-$dll-bytes');
        expect(x32.existsSync(), isTrue, reason: 'syswow64/$dll.dll');
        expect(x32.readAsStringSync(), 'x32-$dll-bytes');
      }
    });

    test('records the version so later runs know', () async {
      cacheDxvk();
      createWindowsDirs();
      expect(DxvkInstaller.isEnabledFor(prefix), isFalse);

      await installerWith().installInto(prefix);

      expect(DxvkInstaller.installedVersion(prefix), pinnedDxvk.version);
      expect(DxvkInstaller.isEnabledFor(prefix), isTrue);
    });

    test('a 64-bit-only prefix still gets its x64 dlls', () async {
      cacheDxvk();
      createWindowsDirs(syswow64: false);

      await installerWith().installInto(prefix);

      expect(
        File(p.join(prefix.path, 'drive_c', 'windows', 'system32', 'd3d11.dll'))
            .existsSync(),
        isTrue,
      );
    });

    test('refuses a prefix Wine has not built yet, with advice', () async {
      cacheDxvk();
      await expectLater(
        installerWith().installInto(prefix),
        throwsA(isA<BuildFailure>()
            .having((e) => e.details ?? '', 'details', contains('--dxvk'))),
      );
    });

    test('disabling clears the marker without touching the dlls', () async {
      cacheDxvk();
      createWindowsDirs();
      await installerWith().installInto(prefix);

      DxvkInstaller.disableFor(prefix);

      expect(DxvkInstaller.isEnabledFor(prefix), isFalse);
      expect(
        File(p.join(prefix.path, 'drive_c', 'windows', 'system32', 'd3d11.dll'))
            .existsSync(),
        isTrue,
        reason: 'the override is what decides; a real reset deletes the prefix',
      );
    });

    test('disabling a prefix that never had it is harmless', () {
      expect(() => DxvkInstaller.disableFor(prefix), returnsNormally);
    });
  });

  group('vulkan detection', () {
    test('reports the loader when one is present', () {
      // This machine's real state either way; the point is that the check
      // answers without throwing and stays vendor-neutral.
      final check = VulkanCheck.detect(ToolResolver(config: configWith()));
      expect(check.looksAvailable, check.loaderPath != null ||
          check.vulkaninfoPath != null);
    });

    test('a vulkaninfo on the search path counts', () {
      writeExecutable(pathDir, 'vulkaninfo');
      final check = VulkanCheck.detect(ToolResolver(config: configWith()));
      expect(check.vulkaninfoPath, p.join(pathDir, 'vulkaninfo'));
      expect(check.looksAvailable, isTrue);
    });

    test('the advice names no GPU vendor', () {
      final advice = VulkanCheck.missingAdvice.toLowerCase();
      for (final vendor in ['nvidia', 'amd', 'intel', 'radeon', 'geforce']) {
        expect(advice, isNot(contains(vendor)), reason: vendor);
      }
      expect(advice, contains('vulkan'));
    });
  });
}
