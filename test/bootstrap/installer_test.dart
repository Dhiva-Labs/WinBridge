import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/bootstrap/components.dart';
import 'package:winbridge/src/bootstrap/installer.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/host.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late String pathDir;
  late String curl;
  late String sha256sum;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
    curl = writeExecutable(pathDir, 'curl');
    writeExecutable(pathDir, 'tar');
    sha256sum = writeExecutable(pathDir, 'sha256sum');
  });

  /// Pretends to download something whose digest never matches a pin, so every
  /// install stops at the checksum — after curl has been asked for its URL and
  /// before anything is unpacked.
  RecordingProcessRunner fakeDownloads() => RecordingProcessRunner(onRun: (call) {
        if (call.executable == curl) {
          writeFile(call.arguments[call.arguments.indexOf('-o') + 1], 'bytes');
          return okResult();
        }
        if (call.executable == sha256sum) {
          return okResult(stdout: '${'e' * 64}  ${call.arguments.single}\n');
        }
        return okResult();
      });

  ComponentInstaller installerFor(
    WinBridgeConfig config,
    RecordingProcessRunner runner,
  ) =>
      ComponentInstaller(
        config: config,
        tools: ToolResolver(config: config),
        runner: runner,
        output: silentOutput(),
      );

  WinBridgeConfig configFor(HostArch arch, {Map<String, String>? extra}) =>
      WinBridgeConfig(
        environment: {'HOME': home, 'PATH': pathDir, ...?extra},
        hostArch: arch,
      );

  String requestedUrl(RecordingProcessRunner runner) =>
      runner.calls.firstWhere((c) => c.executable == curl).arguments.last;

  group('a component downloads the archive built for the host CPU', () {
    for (final arch in HostArch.values) {
      for (final id in ['go', 'zig', 'msvc']) {
        test('$id on ${arch.slug}', () async {
          final runner = fakeDownloads();
          final installer = installerFor(configFor(arch), runner);

          await expectLater(
            installer.install(findComponent(id)!),
            throwsA(isA<BuildFailure>()
                .having((e) => e.message, 'message', contains('checksum'))),
          );

          final expected = findComponent(id)!.assetFor(arch)!;
          expect(requestedUrl(runner), expected.url);
          final other = findComponent(id)!
              .assets
              .all
              .firstWhere((a) => a.url != expected.url);
          expect(runner.calls.expand((c) => c.arguments),
              isNot(contains(other.url)),
              reason: 'never fetch the other architecture\'s binary');
        });
      }
    }

    test('the checksum it enforces is the arm64 one, not the x64 one',
        () async {
      final runner = fakeDownloads();
      await expectLater(
        installerFor(configFor(HostArch.arm64), runner)
            .install(findComponent('go')!),
        throwsA(isA<BuildFailure>().having((e) => e.details ?? '', 'details',
            contains(goToolchain.arm64.sha256))),
      );
    });

    test('isInstalled looks for the pin of this CPU', () {
      // A stamp written for the x64 archive does not vouch for the arm64 one,
      // so a home directory shared between machines re-downloads rather than
      // trusting a binary built for the other CPU.
      final dir = p.join(home, '.cache', 'winbridge', 'toolchains', 'go');
      writeFile(p.join(dir, '.winbridge-verified'),
          'go\n${goToolchain.x64.sha256}\n');
      writeFile(p.join(dir, 'bin', 'go'));

      final x64 = installerFor(configFor(HostArch.x64), fakeDownloads());
      final arm64 = installerFor(configFor(HostArch.arm64), fakeDownloads());
      final go = findComponent('go')!;
      expect(x64.isInstalled(go), isTrue);
      expect(arm64.isInstalled(go), isFalse);
    });
  });

  group('NSIS is a Windows program, so it follows the Wine decision', () {
    test('is refused on arm64, before any download', () async {
      final runner = fakeDownloads();
      await expectLater(
        installerFor(configFor(HostArch.arm64), runner)
            .install(findComponent('nsis')!),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('x86-64'))),
      );
      expect(runner.calls, isEmpty);
    });

    test('is allowed on arm64 when the user supplied their own Wine',
        () async {
      final wine = writeExecutable(tempDir('own-wine'), 'wine');
      final runner = fakeDownloads();
      await expectLater(
        installerFor(
          configFor(HostArch.arm64,
              extra: {WinBridgeConfig.wineVariable: wine}),
          runner,
        ).install(findComponent('nsis')!),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('checksum'))),
      );
      expect(requestedUrl(runner), nsisDistribution.url);
    });

    test('downloads on x64 as before', () async {
      final runner = fakeDownloads();
      await expectLater(
        installerFor(configFor(HostArch.x64), runner)
            .install(findComponent('nsis')!),
        throwsA(isA<BuildFailure>()),
      );
      expect(requestedUrl(runner), nsisDistribution.url);
    });
  });

  group('a CPU WinBridge has no builds for', () {
    test('gets no download at all, never the x64 one', () async {
      final config = UnknownCpuConfig(
        environment: {'HOME': home, 'PATH': pathDir},
      );
      final runner = fakeDownloads();
      final installer = installerFor(config, runner);

      for (final component in installableComponents) {
        expect(installer.isInstalled(component), isFalse, reason: component.id);
        await expectLater(
          installer.install(component),
          throwsA(isA<BuildFailure>()),
          reason: component.id,
        );
      }
      expect(runner.calls, isEmpty);
    });
  });
}
