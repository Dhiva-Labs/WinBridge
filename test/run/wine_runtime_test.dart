import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/host.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late String pathDir;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
  });

  // Pinned to x64 unless a test says otherwise: these tests describe how the
  // x64 runtime resolves, and must mean the same thing on an arm64 CI runner.
  WinBridgeConfig configWith({
    String? wineOverride,
    HostArch hostArch = HostArch.x64,
  }) =>
      WinBridgeConfig(
        environment: {
          'HOME': home,
          'PATH': pathDir,
          WinBridgeConfig.wineVariable: ?wineOverride,
        },
        hostArch: hostArch,
      );

  WineRuntime runtimeWith({
    String? wineOverride,
    ProcessRunner? runner,
    HostArch hostArch = HostArch.x64,
  }) {
    final config = configWith(wineOverride: wineOverride, hostArch: hostArch);
    return WineRuntime(
      config: config,
      tools: ToolResolver(config: config),
      runner: runner ?? RecordingProcessRunner(),
      output: silentOutput(),
    );
  }

  /// A managed runtime directory as a verified install would leave it.
  String installManaged({String? stampContents}) {
    final dir = p.join(
      home,
      '.cache',
      'winbridge',
      'runtimes',
      pinnedWineBuild.name,
    );
    final wine = writeExecutable(p.join(dir, 'bin'), 'wine');
    if (stampContents != null) {
      writeFile(p.join(dir, WineRuntime.stampFileName), stampContents);
    }
    return wine;
  }

  String validStamp() => '${pinnedWineBuild.name}\n${pinnedWineBuild.sha256}\n';

  group('the pinned build', () {
    test('names an exact upstream release with a checksum', () {
      expect(pinnedWineBuild.version, '11.14');
      expect(pinnedWineBuild.name, 'wine-11.14-amd64-wow64');
      expect(pinnedWineBuild.sha256, hasLength(64));
      expect(pinnedWineBuild.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(pinnedWineBuild.url, startsWith('https://github.com/Kron4ek/'));
      expect(pinnedWineBuild.url, contains(pinnedWineBuild.version));
    });

    test('locates its loader inside the runtime directory', () {
      expect(wineBinaryIn('/rt'), '/rt/bin/wine');
    });
  });

  group('resolution order', () {
    test('WINBRIDGE_WINE wins over everything', () {
      final override = writeExecutable(tempDir('override'), 'wine');
      installManaged(stampContents: validStamp());
      writeExecutable(pathDir, 'wine');

      final resolved = runtimeWith(wineOverride: override).resolve()!;
      expect(resolved.binary, override);
      expect(resolved.source, WineSource.override);
    });

    test('a verified managed runtime beats PATH', () {
      final managed = installManaged(stampContents: validStamp());
      writeExecutable(pathDir, 'wine');

      final resolved = runtimeWith().resolve()!;
      expect(resolved.binary, managed);
      expect(resolved.source, WineSource.managed);
      expect(resolved.isVerified, isTrue);
    });

    test('PATH is the last resort', () {
      final system = writeExecutable(pathDir, 'wine');
      final resolved = runtimeWith().resolve()!;
      expect(resolved.binary, system);
      expect(resolved.source, WineSource.system);
    });

    test('nothing installed resolves to null', () {
      expect(runtimeWith().resolve(), isNull);
    });

    test('an override that is not executable is a clean usage error', () {
      final notExecutable = writeFile(p.join(tempDir('o'), 'wine'), 'text');
      expect(
        () => runtimeWith(wineOverride: notExecutable).resolve(),
        throwsA(isA<UsageFailure>().having(
            (e) => e.message, 'message', contains('WINBRIDGE_WINE'))),
      );
    });
  });

  // The rule: WinBridge only vouches for a runtime it verified itself. The two
  // paths the user picked deliberately are trusted on their say-so; a managed
  // directory is trusted only on evidence.
  group('an unverified managed runtime is not used', () {
    test('no stamp at all is ignored, even with a runnable wine', () {
      installManaged();
      final system = writeExecutable(pathDir, 'wine');

      final resolved = runtimeWith().resolve()!;
      expect(resolved.binary, system,
          reason: 'fell back to PATH rather than trusting an unstamped dir');
    });

    test('a stamp for a different build is ignored', () {
      installManaged(stampContents: 'wine-9.0\n${'0' * 64}\n');
      final system = writeExecutable(pathDir, 'wine');
      expect(runtimeWith().resolve()!.binary, system);
    });

    test('an unstamped runtime with nothing else present resolves to null', () {
      installManaged();
      expect(runtimeWith().resolve(), isNull);
    });

    test('a stamp without a runnable loader is ignored', () {
      final dir = p.join(
          home, '.cache', 'winbridge', 'runtimes', pinnedWineBuild.name);
      writeFile(p.join(dir, WineRuntime.stampFileName), validStamp());
      expect(runtimeWith().resolve(), isNull);
    });
  });

  group('install', () {
    late String curl;
    late String tar;
    late String sha256sum;

    setUp(() {
      curl = writeExecutable(pathDir, 'curl');
      tar = writeExecutable(pathDir, 'tar');
      sha256sum = writeExecutable(pathDir, 'sha256sum');
    });

    /// Stands in for the three tools install shells out to. [digest] is what
    /// sha256sum reports for the "downloaded" file.
    RecordingProcessRunner fakeTools({required String digest}) {
      return RecordingProcessRunner(onRun: (call) {
        if (call.executable == curl) {
          final target = call.arguments[call.arguments.indexOf('-o') + 1];
          writeFile(target, 'pretend archive bytes');
          return okResult();
        }
        if (call.executable == sha256sum) {
          return okResult(stdout: '$digest  ${call.arguments.single}\n');
        }
        return okResult();
      });
    }

    test('a checksum mismatch aborts before anything is unpacked', () async {
      final runner = fakeTools(digest: 'f' * 64);
      final runtime = runtimeWith(runner: runner);

      await expectLater(
        runtime.install(),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('checksum'))
            .having((e) => e.details ?? '', 'details',
                contains(pinnedWineBuild.sha256))),
      );

      expect(
        runner.calls.map((c) => c.executable),
        isNot(contains(tar)),
        reason: 'tar must never see an archive that failed its checksum',
      );
      expect(Directory(runtime.managedDirectory!).existsSync(), isFalse);
    });

    test('a mismatched download is deleted, not left lying around', () async {
      final runner = fakeTools(digest: 'a' * 64);
      final runtime = runtimeWith(runner: runner);
      await expectLater(runtime.install(), throwsA(isA<BuildFailure>()));

      final runtimeRoot =
          Directory(p.join(home, '.cache', 'winbridge', 'runtimes'));
      final leftovers = runtimeRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tar.xz'));
      expect(leftovers, isEmpty);
    });

    test('an unreadable checksum is a failure, not a pass', () async {
      final runner = RecordingProcessRunner(onRun: (call) {
        if (call.executable == curl) {
          writeFile(call.arguments[call.arguments.indexOf('-o') + 1], 'x');
          return okResult();
        }
        if (call.executable == sha256sum) return okResult(stdout: '');
        return okResult();
      });
      await expectLater(
        runtimeWith(runner: runner).install(),
        throwsA(isA<BuildFailure>()),
      );
    });

    test('a failed download never reaches the checksum step', () async {
      final runner = RecordingProcessRunner(
        onRun: (call) =>
            call.executable == curl ? failResult(stderr: 'no route') : null,
      );
      await expectLater(
        runtimeWith(runner: runner).install(),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('download'))),
      );
      expect(runner.calls.map((c) => c.executable), isNot(contains(sha256sum)));
    });

    test('downloads the pinned url with argv, never a shell string', () async {
      final runner = fakeTools(digest: 'f' * 64);
      await runtimeWith(runner: runner).install().catchError((_) {});

      final download = runner.calls.firstWhere((c) => c.executable == curl);
      expect(download.arguments, contains(pinnedWineBuild.url));
      expect(download.arguments, contains('-fL'));
      expect(
        download.arguments.any((a) => a.contains('&&') || a.contains('|')),
        isFalse,
      );
    });
  });

  // The pinned Wine is an x86-64 program. On an arm64 host it cannot start, no
  // arm64 build of it exists to pin, and a `wine` on PATH is a different CPU's
  // Wine than the one that can run what WinBridge builds. So: nothing is
  // downloaded or guessed, the one explicit escape hatch stays, and the
  // failure comes before any prefix or download exists.
  group('on an arm64 host', () {
    WineRuntime arm64Runtime({String? wineOverride, ProcessRunner? runner}) =>
        runtimeWith(
          wineOverride: wineOverride,
          runner: runner,
          hostArch: HostArch.arm64,
        );

    test('the pinned build is x86-64 only', () {
      expect(pinnedWineRunsOn(HostArch.x64), isTrue);
      expect(pinnedWineRunsOn(HostArch.arm64), isFalse);
      expect(pinnedWineRunsOn(null), isFalse);
      expect(pinnedWineBuild.name, contains('amd64'));
      expect(arm64Runtime().managedBuildSupported, isFalse);
      expect(runtimeWith().managedBuildSupported, isTrue);
    });

    test('a verified managed runtime is not used', () {
      installManaged(stampContents: validStamp());
      expect(arm64Runtime().resolve(), isNull);
    });

    test('a wine on PATH is not guessed at', () {
      writeExecutable(pathDir, 'wine');
      expect(arm64Runtime().resolve(), isNull);
    });

    test('WINBRIDGE_WINE is still honoured, as given and unverified', () {
      final own = writeExecutable(tempDir('own'), 'wine');
      installManaged(stampContents: validStamp());
      writeExecutable(pathDir, 'wine');

      final resolved = arm64Runtime(wineOverride: own).resolve()!;
      expect(resolved.binary, own);
      expect(resolved.source, WineSource.override);
      expect(resolved.isVerified, isFalse);
    });

    test('a bad WINBRIDGE_WINE is still a clean usage error', () {
      final notExecutable = writeFile(p.join(tempDir('o'), 'wine'), 'text');
      expect(
        () => arm64Runtime(wineOverride: notExecutable).resolve(),
        throwsA(isA<UsageFailure>()),
      );
    });

    test('resolveOrInstall fails early, honestly, and downloads nothing',
        () async {
      final runner = RecordingProcessRunner();
      final runtime = arm64Runtime(runner: runner);

      await expectLater(
        runtime.resolveOrInstall(),
        throwsA(isA<BuildFailure>()
            .having((e) => e.message, 'message', contains('x86-64'))
            .having((e) => e.message, 'message', contains('arm64'))
            .having((e) => e.details ?? '', 'details',
                contains(WinBridgeConfig.wineVariable))
            .having((e) => e.details ?? '', 'details',
                contains('Nothing was downloaded'))),
      );

      expect(runner.calls, isEmpty, reason: 'no curl, no tar, nothing');
      expect(Directory(runtime.managedDirectory!).existsSync(), isFalse);
      expect(Directory(p.join(home, '.cache')).existsSync(), isFalse,
          reason: 'not even a cache directory was created');
    });

    test('the message names the pinned build and what still works', () async {
      Object? caught;
      try {
        await arm64Runtime().resolveOrInstall();
      } on Object catch (error) {
        caught = error;
      }
      final failure = caught! as BuildFailure;
      expect(failure.details, contains(pinnedWineBuild.name));
      expect(failure.details, contains('winbridge build'));
      expect(failure.exitCode, 1);
    });

    test('install() cannot be used to sidestep the check', () async {
      final runner = RecordingProcessRunner();
      await expectLater(
        arm64Runtime(runner: runner).install(),
        throwsA(isA<BuildFailure>()),
      );
      expect(runner.calls, isEmpty);
    });

    test('resolveOrInstall still returns the override without complaint',
        () async {
      final own = writeExecutable(tempDir('own'), 'wine');
      final resolved =
          await arm64Runtime(wineOverride: own).resolveOrInstall();
      expect(resolved.binary, own);
    });

    test('an unknown CPU is treated the same way, and says so', () async {
      final config = UnknownCpuConfig(
        environment: {'HOME': home, 'PATH': pathDir},
      );
      final runtime = WineRuntime(
        config: config,
        tools: ToolResolver(config: config),
        runner: RecordingProcessRunner(),
        output: silentOutput(),
      );
      await expectLater(
        runtime.resolveOrInstall(),
        throwsA(isA<BuildFailure>().having(
            (e) => e.message, 'message', contains('neither x86-64 nor arm64'))),
      );
    });
  });
}
