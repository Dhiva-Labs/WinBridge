import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';

/// Authenticode signing via `osslsigncode`.
///
/// The whole design of this file is one rule: **a signing passphrase never
/// appears in an argument vector.** Anything on argv is readable by every
/// process on the machine through `/proc/<pid>/cmdline`, and lands in shell
/// history and CI logs besides. osslsigncode takes the passphrase either from
/// `-readpass <file>` or by prompting; WinBridge uses those two and offers no
/// flag that would carry it.
class Signer {
  const Signer({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
  });

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;

  /// Where a passphrase may come from. Never a command-line option.
  static const passphraseVariable = 'WINBRIDGE_SIGN_PASSPHRASE';

  /// RFC 3161 timestamping, so signatures outlive the certificate.
  static const defaultTimestampUrl = 'http://timestamp.digicert.com';

  bool get isAvailable => tools.resolve('osslsigncode') != null;

  /// Signs [file] in place with [certificate].
  ///
  /// Returns the signed path. Throws [BuildFailure] with an actionable message
  /// when osslsigncode is not installed, rather than silently shipping an
  /// unsigned installer.
  Future<String> sign({
    required String file,
    required String certificate,
    String? timestampUrl,
    bool verbose = false,
  }) async {
    final tool = tools.resolve('osslsigncode');
    if (tool == null) {
      throw const BuildFailure(
        'osslsigncode is not installed, so the installer was not signed',
        details: 'Install it and run again — on Debian and Ubuntu that is '
            '`osslsigncode`. WinBridge does not download it: it is a small '
            'distribution package and signing is not something to bootstrap '
            'silently.\n'
            'To build without signing, drop --sign.',
      );
    }
    if (!File(certificate).existsSync()) {
      throw UsageFailure('no such certificate file: $certificate');
    }

    final passphrase = _readPassphrase();
    final signed = '$file.signed';

    // The passphrase goes to a file only this user can read, and the file is
    // removed before this method returns whatever happens.
    File? passphraseFile;
    try {
      final arguments = signArguments(
        certificate: certificate,
        input: file,
        output: signed,
        timestampUrl: timestampUrl ?? defaultTimestampUrl,
      );

      if (passphrase != null) {
        passphraseFile = _writePassphraseFile(passphrase);
        arguments.addAll(['-readpass', passphraseFile.path]);
      } else {
        output.info('osslsigncode will prompt for the certificate passphrase.');
      }

      final result = await runner.run(
        tool.path,
        arguments,
        streamOutput: passphrase == null,
        captureOutput: true,
      );
      if (!result.ok) {
        throw BuildFailure(
          'signing failed (exit ${result.exitCode})',
          details: result.diagnostics,
        );
      }
    } finally {
      if (passphraseFile != null) {
        final directory = passphraseFile.parent;
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    }

    // osslsigncode cannot sign in place, so it wrote beside the original.
    File(signed).renameSync(file);
    output.detail('signed $file');
    return file;
  }

  String? _readPassphrase() {
    final fromEnvironment = config.environment[passphraseVariable];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      return fromEnvironment;
    }
    return null;
  }

  /// `createTempSync` makes the directory 0700, so the passphrase is readable
  /// only by this user for the few seconds it exists.
  File _writePassphraseFile(String passphrase) {
    final directory = Directory.systemTemp.createTempSync('winbridge-sign-');
    final file = File(p.join(directory.path, 'passphrase'));
    file.writeAsStringSync(passphrase);
    return file;
  }
}

/// The argument vector for a signing run.
///
/// Exposed so a test can assert what it does *not* contain: no `-pass`, and
/// nothing resembling a secret. That test is the enforcement — a future change
/// that adds a passphrase option here fails it.
List<String> signArguments({
  required String certificate,
  required String input,
  required String output,
  required String timestampUrl,
}) =>
    [
      'sign',
      '-pkcs12', certificate,
      '-h', 'sha256',
      '-ts', timestampUrl,
      '-in', input,
      '-out', output,
    ];
