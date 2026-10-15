import 'dart:ffi' show Abi;

import 'package:test/test.dart';
import 'package:winbridge/winbridge.dart';

void main() {
  group('HostArch', () {
    test('names each architecture the way release assets, uname and dpkg do',
        () {
      expect(HostArch.x64.slug, 'x64');
      expect(HostArch.x64.machine, 'x86_64');
      expect(HostArch.x64.debian, 'amd64');
      expect(HostArch.arm64.slug, 'arm64');
      expect(HostArch.arm64.machine, 'aarch64');
      expect(HostArch.arm64.debian, 'arm64');
    });

    test('maps the two Linux ABIs WinBridge has builds for', () {
      expect(HostArch.fromAbi(Abi.linuxX64), HostArch.x64);
      expect(HostArch.fromAbi(Abi.linuxArm64), HostArch.arm64);
    });

    test('maps every other ABI to null, never to a default', () {
      for (final abi in [
        Abi.linuxArm,
        Abi.linuxIA32,
        Abi.linuxRiscv64,
        Abi.macosArm64,
        Abi.windowsX64,
      ]) {
        expect(HostArch.fromAbi(abi), isNull, reason: '$abi');
      }
    });

    test('detects the machine the tests run on as one of the two', () {
      // Whichever CI leg this is, it must be one WinBridge ships for.
      expect(HostArch.detect(), isNotNull);
    });

    test('parses every spelling tools use', () {
      for (final spelling in ['x64', 'x86_64', 'X86-64', 'amd64']) {
        expect(HostArch.parse(spelling), HostArch.x64, reason: spelling);
      }
      for (final spelling in ['arm64', 'aarch64', ' AArch64 ']) {
        expect(HostArch.parse(spelling), HostArch.arm64, reason: spelling);
      }
      expect(HostArch.parse('riscv64'), isNull);
      expect(HostArch.parse(''), isNull);
    });
  });

  group('WinBridgeConfig.hostArch', () {
    test('defaults to the machine the process runs on', () {
      expect(WinBridgeConfig(environment: const {}).hostArch,
          HostArch.detect());
    });

    test('can be pinned, so either architecture is testable anywhere', () {
      expect(
        WinBridgeConfig(environment: const {}, hostArch: HostArch.arm64)
            .hostArch,
        HostArch.arm64,
      );
      expect(
        WinBridgeConfig(environment: const {}, hostArch: HostArch.x64)
            .hostArch,
        HostArch.x64,
      );
    });
  });
}
