import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/run/wine_runtime.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../toolchains/support.dart';

void main() {
  late String home;
  late String pathDir;

  setUp(() {
    home = tempDir('home');
    pathDir = tempDir('path');
  });

  WinBridgeConfig configWith({String? wineOverride}) =>
      WinBridgeConfig(environment: {
        'HOME': home,
        'PATH': pathDir,
        WinBridgeConfig.wineVariable: ?wineOverride,
      });

  WineRuntime runtimeWith({
    String? wineOverride,
    ProcessRunner? runner,
  }) {
    final config = configWith(wineOverride: wineOverride);
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
}
