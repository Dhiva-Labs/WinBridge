import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/report/report_gatherer.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';
import '../support/toolchains.dart';
import 'support/fake_process_runner.dart';

void main() {
  late String home;
  late String toolDir;
  late FakeProcessRunner runner;

  setUp(() {
    home = tempDir('home');
    toolDir = tempDir('bin');
    runner = FakeProcessRunner();
  });

  ToolResolver toolsWith({String? path}) => ToolResolver(
        environment: {'HOME': home, 'PATH': ?path},
      );

  String missingCpuInfoPath() => p.join(tempDir('no-cpuinfo'), 'missing');

  group('gather', () {
    test('reports kernel, cpu and gpu when every tool is present', () async {
      writeExecutable(toolDir, 'uname');
      writeExecutable(toolDir, 'lspci');
      runner.responses.addAll([
        okResult(stdout: 'Linux 6.8.0-49-generic x86_64 GNU/Linux\n'),
        okResult(
          stdout: '01:00.0 VGA compatible controller [0300]: Acme Widgets '
              'GPU [1234:5678] (rev 01)\n',
        ),
      ]);
      final cpuinfo = writeFile(
        p.join(tempDir('cpuinfo'), 'cpuinfo'),
        'processor\t: 0\nmodel name\t: Acme CPU X1\n\n',
      );

      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(path: toolDir),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: cpuinfo,
      );

      final report = await gatherer.gather();

      expect(report.kernel, 'Linux 6.8.0-49-generic x86_64 GNU/Linux');
      expect(report.cpuModel, 'Acme CPU X1');
      expect(report.gpus, hasLength(1));
      expect(report.gpus.single.description, contains('Acme Widgets GPU'));
      expect(report.lspciAvailable, isTrue);

      // uname must never be asked for `-a`/`-n`: either would print the
      // machine's network hostname, which this report may never carry.
      final unameCall = runner.calls.first;
      expect(unameCall.arguments, isNot(contains('-a')));
      expect(unameCall.arguments, isNot(contains('-n')));
    });

    test('degrades gracefully when uname and lspci are both missing', () async {
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(), // empty PATH: nothing resolves
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: missingCpuInfoPath(),
      );

      final report = await gatherer.gather();

      expect(report.kernel, isNull);
      expect(report.cpuModel, isNull);
      expect(report.gpus, isEmpty);
      expect(report.lspciAvailable, isFalse);
      expect(runner.calls, isEmpty,
          reason: 'nothing to run when neither tool resolved');

      final markdown = report.toMarkdown();
      expect(markdown, contains('uname unavailable'));
      expect(markdown, contains('lspci not found'));
    });

    test('a failing lspci call is reported as available-but-empty, not a crash', () async {
      writeExecutable(toolDir, 'lspci');
      runner.responses.add(failResult());

      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(path: toolDir),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: missingCpuInfoPath(),
      );

      final report = await gatherer.gather();
      expect(report.lspciAvailable, isTrue);
      expect(report.gpus, isEmpty);
      expect(report.toMarkdown(), contains('lspci found no VGA or 3D controller'));
    });

    test('wine resolved via WINBRIDGE_WINE is reported with its path redacted', () async {
      final wineBin = writeExecutable(p.join(home, 'my-wine'), 'wine');
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(environment: {
          'HOME': home,
          'WINBRIDGE_WINE': wineBin,
        }),
        cpuInfoPath: missingCpuInfoPath(),
      );

      final report = await gatherer.gather();
      expect(report.wine.resolved, isTrue);
      expect(report.wine.sourceLabel, 'WINBRIDGE_WINE');
      expect(report.wine.binaryPath, startsWith('~/'));
      expect(report.wine.binaryPath, isNot(contains(home)));
    });

    test('no wine installed yet is reported honestly, not as an error', () async {
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(
          environment: {'HOME': home},
          hostArch: HostArch.x64,
        ),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final report = await gatherer.gather();
      expect(report.wine.resolved, isFalse);
      expect(report.wine.pinnedVersion, isNotEmpty);
      expect(report.wine.unavailableOnHost, isFalse);
      expect(
        report.toMarkdown(),
        contains('installs automatically on first `winbridge run`'),
      );
    });

    test('an arm64 host is told Wine is unavailable, not that it will install',
        () async {
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(
          environment: {'HOME': home},
          hostArch: HostArch.arm64,
        ),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final report = await gatherer.gather();
      expect(report.wine.resolved, isFalse);
      expect(report.wine.unavailableOnHost, isTrue);
      expect(report.wine.hostArch, 'arm64');
      final markdown = report.toMarkdown();
      expect(markdown, contains('x86-64 only'));
      expect(markdown, contains('this host is arm64'));
      expect(markdown, isNot(contains('installs automatically')));
    });

    test('an arm64 cpuinfo has no model name, so the board name stands in',
        () async {
      writeExecutable(toolDir, 'uname');
      runner.responses.add(
        okResult(stdout: 'Linux 6.8.0-1017-raspi aarch64 GNU/Linux\n'),
      );
      final cpuinfo = writeFile(
        p.join(tempDir('cpuinfo'), 'cpuinfo'),
        'processor\t: 0\nBogoMIPS\t: 108.00\nCPU implementer\t: 0x41\n'
        '\nHardware\t: BCM2712\nModel\t\t: Raspberry Pi 5 Model B Rev 1.0\n',
      );
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(path: toolDir),
        config: WinBridgeConfig(
          environment: {'HOME': home},
          hostArch: HostArch.arm64,
        ),
        cpuInfoPath: cpuinfo,
      );
      final report = await gatherer.gather();
      expect(report.kernel, contains('aarch64'));
      expect(report.cpuModel, 'BCM2712');
    });

    test('an x86 model name wins over any board line', () async {
      final cpuinfo = writeFile(
        p.join(tempDir('cpuinfo'), 'cpuinfo'),
        'Hardware\t: Some Board\nmodel name\t: Acme CPU X1\n',
      );
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: cpuinfo,
      );
      expect((await gatherer.gather()).cpuModel, 'Acme CPU X1');
    });

    test('prefixes report their DXVK state without claiming rendering works', () async {
      final prefixesRoot =
          p.join(home, '.local', 'share', 'winbridge', 'prefixes');
      final withDxvk = Directory(p.join(prefixesRoot, 'game'))
        ..createSync(recursive: true);
      writeFile(p.join(withDxvk.path, '.winbridge-dxvk'), '3.0.2\n');
      Directory(p.join(prefixesRoot, 'plain')).createSync(recursive: true);

      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final report = await gatherer.gather();

      final game = report.prefixes.firstWhere((prefix) => prefix.name == 'game');
      expect(game.dxvkVersion, '3.0.2');
      final plain = report.prefixes.firstWhere((prefix) => prefix.name == 'plain');
      expect(plain.dxvkVersion, isNull);

      expect(report.toMarkdown(), contains('rendering unverified'));
    });

    test('prefix list is empty rather than an error when none exist yet', () async {
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final report = await gatherer.gather();
      expect(report.prefixes, isEmpty);
      expect(report.toMarkdown(), contains('no app prefixes yet'));
    });

    test(
      'toolchain readiness mirrors doctor: found and optional both count, '
      'missing required does not',
      () async {
        writeExecutable(toolDir, 'go');
        final ready = FakeToolchain(
          id: 'go',
          handles: const {ProjectType.go},
          description: 'cross-compiles Go for windows/amd64',
          requires: const [ToolRequirement(tool: 'go', reason: 'compiles Go')],
        );
        final notReady = FakeToolchain(
          id: 'rust',
          handles: const {ProjectType.rust},
          description: 'cross-compiles Rust for windows/amd64',
          requires: const [
            ToolRequirement(tool: 'cargo', reason: 'compiles Rust'),
          ],
        );
        final optionalOnly = FakeToolchain(
          id: 'c',
          handles: const {ProjectType.c},
          description: 'compiles C for windows/amd64',
          requires: const [
            ToolRequirement(tool: 'zig', reason: 'cgo linking', optional: true),
          ],
        );

        final gatherer = ReportGatherer(
          runner: runner,
          tools: toolsWith(path: toolDir),
          config: WinBridgeConfig(environment: {'HOME': home}),
          toolchains: [ready, notReady, optionalOnly],
          cpuInfoPath: missingCpuInfoPath(),
        );
        final report = await gatherer.gather();

        expect(
          report.toolchains.firstWhere((t) => t.id == 'go').isReady,
          isTrue,
        );
        expect(
          report.toolchains.firstWhere((t) => t.id == 'rust').isReady,
          isFalse,
        );
        expect(
          report.toolchains.firstWhere((t) => t.id == 'c').isReady,
          isTrue,
        );

        final markdown = report.toMarkdown();
        expect(markdown, contains('toolchains ready to build: go, c'));
        expect(markdown, contains('toolchains not ready: rust'));
      },
    );
  });

  group('privacy', () {
    test('a fake HOME never appears anywhere in the rendered markdown', () async {
      writeExecutable(toolDir, 'uname');
      writeExecutable(toolDir, 'lspci');
      runner.responses.addAll([
        okResult(stdout: 'Linux 6.8.0-49-generic x86_64 GNU/Linux\n'),
        okResult(stdout: ''),
      ]);
      final wineBin = writeExecutable(p.join(home, 'wine-dir'), 'wine');

      final prefixesRoot =
          p.join(home, '.local', 'share', 'winbridge', 'prefixes');
      Directory(p.join(prefixesRoot, 'game')).createSync(recursive: true);

      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(path: toolDir),
        config: WinBridgeConfig(environment: {
          'HOME': home,
          'WINBRIDGE_WINE': wineBin,
        }),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final report = await gatherer.gather();
      final markdown = report.toMarkdown();

      expect(markdown, isNot(contains(home)));
    });

    test('markdown contains every hardware-report template heading', () async {
      final gatherer = ReportGatherer(
        runner: runner,
        tools: toolsWith(),
        config: WinBridgeConfig(environment: {'HOME': home}),
        cpuInfoPath: missingCpuInfoPath(),
      );
      final markdown = (await gatherer.gather()).toMarkdown();

      for (final heading in [
        '**Device**',
        '**Ids**',
        '**Distro / kernel**',
        '**What works natively**',
        '**What needed the VM**',
        "**What doesn't work at all**",
        '**Notes**',
      ]) {
        expect(markdown, contains(heading));
      }
    });
  });
}
