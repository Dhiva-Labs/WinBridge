import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:winbridge/src/cli/runner.dart';
import 'package:winbridge/src/recipes/recipes.dart';
import 'package:winbridge/winbridge.dart';

import '../pe/support.dart';
import '../support/fixtures.dart';

/// What WinBridge does on a Linux arm64 machine, driven through the real CLI
/// wiring with the architecture injected, so the x64 CI leg proves the arm64
/// behaviour and the arm64 leg proves the x64 behaviour is not what it falls
/// back on by accident.
///
/// The contract: building keeps working, everything that needs the x86-64
/// Wine stops *first* with an honest message, nothing is downloaded and no
/// prefix is created, and `WINBRIDGE_WINE` stays the one explicit way through.
void main() {
  late String home;
  late String exe;
  final sha256sumAvailable =
      ToolResolver(config: WinBridgeConfig()).resolve('sha256sum') != null;

  setUp(() {
    home = tempDir('home');
    exe = p.join(tempDir('app'), 'hello.exe');
    File(exe).writeAsBytesSync(buildPeHeader());
  });

  WinBridgeRunner runnerFor(
    HostArch arch,
    StringBuffer out, {
    Map<String, String> env = const {},
    String? path,
  }) =>
      WinBridgeRunner(
        config: WinBridgeConfig(
          environment: {'HOME': home, 'PATH': path ?? '', ...env},
          hostArch: arch,
        ),
        out: out,
        err: out,
      );

  String prefixesDir() =>
      p.join(home, '.local', 'share', 'winbridge', 'prefixes');

  void expectNothingWasCreated() {
    expect(Directory(p.join(home, '.cache')).existsSync(), isFalse,
        reason: 'nothing downloaded or cached');
    expect(Directory(prefixesDir()).existsSync(), isFalse,
        reason: 'no prefix created');
  }

  void expectHonestWineFailure(int code, StringBuffer out) {
    final text = out.toString();
    expect(code, 1);
    expect(text, contains("WinBridge's Wine is x86-64 only"));
    expect(text, contains('arm64 (aarch64)'));
    expect(text, contains('Nothing was downloaded'));
    expect(text, contains(WinBridgeConfig.wineVariable));
    expect(text, contains('winbridge build'));
  }

  group('commands that need Wine fail first, honestly', () {
    test('run', () async {
      final out = StringBuffer();
      final code = await runnerFor(HostArch.arm64, out).execute(['run', exe]);
      expectHonestWineFailure(code, out);
      expectNothingWasCreated();
    });

    test('run --dxvk does not get as far as DXVK', () async {
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.arm64, out).execute(['run', '--dxvk', exe]);
      expectHonestWineFailure(code, out);
      expectNothingWasCreated();
      expect(out.toString(), isNot(contains('Vulkan')));
    });

    test('prefix tricks', () async {
      final out = StringBuffer();
      final code = await runnerFor(HostArch.arm64, out)
          .execute(['prefix', 'tricks', 'mygame', 'corefonts']);
      expectHonestWineFailure(code, out);
      expectNothingWasCreated();
    });

    test('package', () async {
      final project = projectDir({'go.mod': 'module demo\n\ngo 1.22\n'});
      writeBytes(
        p.join(project, 'build', 'winbridge', 'windows-x64', 'demo.exe'),
        buildPeHeader(),
      );
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.arm64, out).execute(['package', project]);
      expectHonestWineFailure(code, out);
      expectNothingWasCreated();
    });

    test(
      'recipe apply',
      () async {
        final recipes = tempDir('recipes');
        writeFile(
          p.join(recipes, 'known.json'),
          jsonEncode({
            'id': 'known-needs-fonts',
            'match': {
              'sha256':
                  'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
            },
            'apply': {
              'tricks': ['corefonts'],
            },
          }),
        );
        final setup = writeFile(p.join(tempDir('app'), 'Setup.exe'), 'hello world');

        final out = StringBuffer();
        final code = await runnerFor(
          HostArch.arm64,
          out,
          path: Platform.environment['PATH'],
          env: {bundledRecipesDirVariable: recipes},
        ).execute(['recipe', 'apply', setup]);
        expectHonestWineFailure(code, out);
        expectNothingWasCreated();
      },
      skip: sha256sumAvailable ? false : 'no sha256sum on PATH',
    );

    test('a wine on PATH does not rescue it', () async {
      final bin = tempDir('bin');
      writeExecutable(bin, 'wine');
      final out = StringBuffer();
      final code = await runnerFor(HostArch.arm64, out, path: bin)
          .execute(['run', exe]);
      expectHonestWineFailure(code, out);
    });
  });

  group('WINBRIDGE_WINE is the way through', () {
    test('run uses the Wine the user named, with no download', () async {
      final wine = writeExecutable(tempDir('own'), 'wine');
      final out = StringBuffer();
      final code = await runnerFor(
        HostArch.arm64,
        out,
        env: {WinBridgeConfig.wineVariable: wine},
      ).execute(['run', exe]);

      expect(code, 0, reason: out.toString());
      expect(out.toString(), isNot(contains('x86-64 only')));
      expect(Directory(p.join(home, '.cache')).existsSync(), isFalse);
    });
  });

  group('commands that do not need Wine are unaffected', () {
    test('prefix list', () async {
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.arm64, out).execute(['prefix', 'list']);
      expect(code, 0);
      expect(out.toString(), contains('no app prefixes yet'));
    });

    test('--version', () async {
      final out = StringBuffer();
      final code = await runnerFor(HostArch.arm64, out).execute(['--version']);
      expect(code, 0);
      expect(out.toString(), startsWith('winbridge '));
    });

    test('detect', () async {
      final project = projectDir({'go.mod': 'module demo\n\ngo 1.22\n'});
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.arm64, out).execute(['detect', project]);
      expect(code, 0);
      expect(out.toString().toLowerCase(), contains('go'));
    });
  });

  group('doctor reports the host and the Wine situation', () {
    Future<String> doctor(HostArch arch, {Map<String, String> env = const {}}) async {
      final out = StringBuffer();
      // Exit code is not the point: with an empty PATH the toolchains are
      // missing on purpose, which is a 1 on either architecture.
      await runnerFor(arch, out, env: env).execute(['doctor']);
      return out.toString();
    }

    test('says it is an arm64 host and that Wine is unavailable', () async {
      final text = await doctor(HostArch.arm64);
      expect(text, contains('Host: linux arm64 (aarch64)'));
      expect(text, contains('n/a      wine'));
      expect(text, contains('unavailable on arm64'));
      expect(text, contains('x86-64 only'));
      expect(text, contains(WinBridgeConfig.wineVariable));
      expect(text, isNot(contains('installed automatically on first')));
    });

    test('Wine being unavailable is not a failure of doctor itself', () async {
      final out = StringBuffer();
      final code = await WinBridgeRunner(
        registry: ToolchainRegistry(const []),
        config: WinBridgeConfig(
          environment: {'HOME': home, 'PATH': ''},
          hostArch: HostArch.arm64,
        ),
        out: out,
        err: out,
      ).execute(['doctor']);
      expect(code, 0, reason: out.toString());
    });

    test('reports the user\'s own Wine when one is set', () async {
      final wine = writeExecutable(tempDir('own'), 'wine');
      final text =
          await doctor(HostArch.arm64, env: {WinBridgeConfig.wineVariable: wine});
      expect(text, contains('ok       wine'));
      expect(text, contains(wine));
      expect(text, isNot(contains('n/a      wine')));
    });

    test('lists the arm64 downloads, and marks the Wine-only one n/a', () async {
      final text = await doctor(HostArch.arm64);
      final components = text
          .split('\n')
          .where((l) => RegExp(r'^\s+(absent|system|managed|partial|n/a)\s')
              .hasMatch(l))
          .toList();
      expect(components.any((l) => l.contains(' go ') && l.contains('64 MB')),
          isTrue,
          reason: components.join('\n'));
      expect(components.any((l) => l.contains(' zig ') && l.contains('51 MB')),
          isTrue);
      expect(
        components.any((l) =>
            l.trimLeft().startsWith('n/a') &&
            l.contains(' nsis ') &&
            l.contains('needs Wine')),
        isTrue,
        reason: components.join('\n'),
      );
    });

    test('an x64 host is unchanged', () async {
      final text = await doctor(HostArch.x64);
      expect(text, contains('Host: linux x64 (x86_64)'));
      expect(text, contains('absent   wine'));
      expect(text, contains('installed automatically on first'));
      expect(text, isNot(contains('n/a')));
      expect(text, contains('67 MB'));
    });

    test('doctor --install nsis is refused on arm64, before downloading',
        () async {
      final out = StringBuffer();
      final code = await runnerFor(HostArch.arm64, out)
          .execute(['doctor', '--install', 'nsis']);
      expect(code, 1);
      expect(out.toString(), contains('x86-64'));
      expectNothingWasCreated();
    });
  });

  group('desktop add', () {
    test('warns on arm64 that the launcher will not start the app', () async {
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.arm64, out).execute(['desktop', 'add', exe]);
      expect(code, 0, reason: 'the entry itself is still valid');
      expect(out.toString(), contains('warning'));
      expect(out.toString(), contains(WinBridgeConfig.wineVariable));
    });

    test('does not warn on x64', () async {
      final out = StringBuffer();
      final code =
          await runnerFor(HostArch.x64, out).execute(['desktop', 'add', exe]);
      expect(code, 0);
      expect(out.toString(), isNot(contains('warning')));
    });

    test('does not warn on arm64 when the user has set their own Wine',
        () async {
      final wine = writeExecutable(tempDir('own'), 'wine');
      final out = StringBuffer();
      final code = await runnerFor(
        HostArch.arm64,
        out,
        env: {WinBridgeConfig.wineVariable: wine},
      ).execute(['desktop', 'add', exe]);
      expect(code, 0);
      expect(out.toString(), isNot(contains('warning')));
    });
  });
}
