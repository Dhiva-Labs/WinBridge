import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// These scripts are not Dart, so they cannot be exercised through `dart
/// test` the way the transport and config code is — per the task brief, no
/// execution tests. What is checkable without a shell or a VM is that the
/// source itself has no obvious quoting holes: the same charsets `VmConfig`
/// enforces show up here too, nothing wraps a remote command in a redundant
/// `cmd /c` (Windows OpenSSH already runs whatever it receives through
/// cmd.exe), and every value handed to the remote command line goes through
/// the script's own quoting helper rather than being spliced in raw.
void main() {
  final repoRoot = _repoRoot();
  final printScript =
      File(p.join(repoRoot, 'scripts', 'printing', 'winbridge-print.sh'));
  final watcherScript =
      File(p.join(repoRoot, 'scripts', 'printing', 'print-vm-side.ps1'));

  group('winbridge-print.sh', () {
    late String source;

    setUp(() {
      expect(printScript.existsSync(), isTrue, reason: '${printScript.path} missing');
      source = printScript.readAsStringSync();
    });

    test('fails fast on any error', () {
      expect(source, contains('set -euo pipefail'));
    });

    test('never evaluates a dynamically built string', () {
      expect(source, isNot(contains('eval ')));
      expect(source, isNot(contains(r'eval "')));
    });

    test('validates host, user, workspace and printer with the exact '
        'charsets VmConfig enforces', () {
      // Keep these in sync with lib/src/vm/vm_config.dart by hand — that
      // file is Dart and cannot be imported into a shell script, so this
      // test is the tripwire if the two ever drift apart.
      expect(source, contains(r"host_pattern='^[A-Za-z0-9._-]+$'"));
      expect(source, contains(r"user_pattern='^[A-Za-z0-9._-]+$'"));
      expect(source, contains(r"workspace_pattern='^[A-Za-z0-9:/_.-]+$'"));
      expect(source, contains(r"printer_pattern='^[A-Za-z0-9 ._-]+$'"));
    });

    test('rejects ".." in workspace and sumatra-path explicitly', () {
      expect(source, contains(r'$workspace" == *..*'));
      expect(source, contains(r'$sumatra_path" == *..*'));
    });

    test('every remote command is built from the argv-per-token pattern, '
        'never a single interpolated string', () {
      // The invariant remote_command.dart documents: nothing is handed to
      // ssh as one big pre-joined command string. Command substitution is
      // fine elsewhere in the script (building a local temp file name, for
      // instance) — what must never happen is a run_remote call itself
      // containing one, which would mean a token was assembled inline
      // instead of coming from a validated variable.
      final runRemoteLines = source
          .split('\n')
          .where((line) => line.trimLeft().startsWith('run_remote'));
      expect(runRemoteLines, isNotEmpty);
      for (final line in runRemoteLines) {
        expect(line, isNot(contains(r'$(')),
            reason: 'command substitution inline in a remote call: $line');
      }
    });

    test('never wraps a remote call in its own cmd /c', () {
      // ssh already invokes the VM's default shell (cmd.exe) with whatever
      // it receives; prefixing `cmd /c` ourselves would just nest a second
      // shell for no reason. Grep for the literal token pair, not just the
      // substring "cmd", which would also match "SumatraPDF" false-negatives
      // in reverse — check the specific `run_remote cmd /c` shape is absent.
      expect(source, isNot(contains('run_remote cmd')));
    });

    test('quotes every value spliced into a remote command through '
        'quote_remote before it reaches run_remote', () {
      final quoteFn = source.contains('quote_remote()');
      expect(quoteFn, isTrue);

      // Every run_remote call that touches a path or the printer name uses
      // the _q-suffixed (already-quoted) variable, never the raw one.
      final runRemoteLines = source
          .split('\n')
          .where((line) => line.trimLeft().startsWith('run_remote'));
      for (final line in runRemoteLines) {
        for (final raw in ['\$remote_dir"', '\$remote_pdf"', '\$sumatra_path"', '\$printer"']) {
          expect(line, isNot(contains(raw)),
              reason: 'unquoted value spliced directly into: $line');
        }
      }
    });

    test('the remote file name is generated locally, never derived from the '
        'input file name or a job title', () {
      expect(source, contains('generate_remote_token'));
      expect(source, contains(r'$(date +%s)'));
      // The line that actually builds remote_pdf must be built only from
      // remote_dir and the generated token — $pdf_file (the caller-supplied
      // input path, used elsewhere purely to *read* the local file) must
      // never appear on it.
      final remotePdfLine =
          source.split('\n').firstWhere((line) => line.trimLeft().startsWith('remote_pdf='));
      expect(remotePdfLine, isNot(contains('pdf_file')));
      expect(remotePdfLine, contains('remote_token'));
    });

    test('the EXIT trap cannot leak a nonzero status from an empty cleanup', () {
      // A `[[ -n "$f" ]] && rm ...` as the loop's last statement would make
      // cleanup() return non-zero whenever there is nothing to remove, and
      // bash uses an EXIT trap's own exit status as the script's final one —
      // silently turning every successful run with a given (not piped) PDF
      // into an apparent failure. Confirmed by hand with a real dry run;
      // this guards against it coming back.
      expect(source, contains('return 0'));
      expect(source, isNot(contains('&& rm -f')));
    });

    test('checks for ssh and scp before touching the network', () {
      expect(source, contains('command -v ssh'));
      expect(source, contains('command -v scp'));
    });

    test('identityFile-equivalent is checked for whitespace, like VmConfig', () {
      expect(source, contains('must not contain whitespace'));
    });
  });

  group('print-vm-side.ps1', () {
    late String source;

    setUp(() {
      expect(watcherScript.existsSync(), isTrue, reason: '${watcherScript.path} missing');
      source = watcherScript.readAsStringSync();
    });

    test('space-capable arguments to SumatraPDF carry their own quotes', () {
      // Start-Process does not quote the elements of -ArgumentList: it is
      // documented to join the array with single spaces. Relying on the array
      // form alone breaks the moment a printer is called "Office Printer" or
      // a path lands under C:\Users\Some Name\ — SumatraPDF then sees two
      // arguments and prints nothing.
      expect(source, contains('\'"{0}"\''));
      expect(source, contains(r'-f $Printer'));
      expect(source, contains(r'-f $file.FullName'));
      expect(
        source,
        isNot(contains(r"@('-print-to', $Printer")),
        reason: 'the unquoted array form splits on the printer name',
      );
    });

    test('never evaluates a dynamically built string', () {
      expect(source, isNot(contains('Invoke-Expression')));
      expect(source, isNot(contains('iex ')));
    });

    test('is idempotent: processed files move out of the watch folder', () {
      expect(source, contains('Move-Unique'));
      expect(source, contains('processedFolder'));
      expect(source, contains('failedFolder'));
    });

    test('stops with a clear error when SumatraPDF is missing', () {
      expect(source, contains('SumatraPDF not found'));
    });
  });

  test('setup-windows.ps1 SumatraPDF install stays behind -WithPrinting '
      'and never re-evaluates a downloaded string', () {
    final setupScript =
        File(p.join(repoRoot, 'scripts', 'vm', 'setup-windows.ps1'));
    expect(setupScript.existsSync(), isTrue);
    final source = setupScript.readAsStringSync();

    expect(source, contains(r'[switch]$WithPrinting'));
    expect(source, contains(r'if ($WithPrinting) {'));

    // The SumatraPDF section specifically must not eval anything it
    // downloads — unlike the pre-existing Chocolatey bootstrap (not this
    // module's code), which is reviewed separately.
    final sumatraSection = source.substring(
      source.indexOf('# SumatraPDF —'),
      source.indexOf('# OpenSSH Server'),
    );
    expect(sumatraSection, isNot(contains('Invoke-Expression')));
    expect(sumatraSection, contains('Invoke-WebRequest'));
    expect(sumatraSection, contains('Expand-Archive'));
  });
}

String _repoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('could not find repo root (no pubspec.yaml above ${Directory.current.path})');
    }
    dir = parent;
  }
  return dir.path;
}
