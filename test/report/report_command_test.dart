import 'package:test/test.dart';
import 'package:winbridge/src/cli/runner.dart';
import 'package:winbridge/src/report/report.dart';
import 'package:winbridge/winbridge.dart';

import '../support/fixtures.dart';

/// End-to-end coverage through the real CLI wiring, built by hand exactly
/// the way the composition root will — the same pattern
/// `desktop_command_test.dart` uses for `DesktopCommand`. The tech lead's
/// slice wires `addCommand(ReportCommand())` into `lib/src/cli/runner.dart`
/// itself; this file proves the command behaves once that one line lands,
/// without touching that file.
void main() {
  test('prints every template heading and the sharing url, and exits 0', () async {
    final home = tempDir('home');
    final out = StringBuffer();
    // No PATH at all: uname/lspci are unresolvable here, so this run is
    // hermetic and never depends on what happens to be installed on the
    // machine running the suite — it exercises the same graceful-degradation
    // path a CI runner without `pciutils` would hit for real.
    final runner = WinBridgeRunner(
      config: WinBridgeConfig(environment: {'HOME': home}),
      out: out,
      err: out,
    );

    final code = await runner.execute(['report']);

    expect(code, 0);
    final text = out.toString();
    for (final heading in [
      '**Device**',
      '**Ids**',
      '**Distro / kernel**',
      '**What works natively**',
      '**What needed the VM**',
      "**What doesn't work at all**",
      '**Notes**',
    ]) {
      expect(text, contains(heading));
    }
    expect(text, contains(hardwareReportIssueUrl));
    expect(text, contains('Nothing above was sent anywhere'));
    expect(text, contains('winbridge $packageVersion'));
    expect(text, isNot(contains(home)));
  });
}
