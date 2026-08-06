@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The security gate for M1: argv-only process execution, enforced by reading
/// the source rather than by trusting review.
///
/// `ProcessRunner` is the only place allowed to touch `Process`, so a toolchain
/// adapter or the VM driver cannot quietly grow its own spawning path — the
/// suite fails the moment one does.
void main() {
  final root = Directory.current.path;

  /// This file necessarily contains the very strings it forbids.
  const scanner = 'test/core/no_shell_test.dart';

  const mayUseProcess = {'lib/src/core/process_runner.dart'};

  final sources = <String, String>{
    for (final file in _dartFiles(root))
      p.relative(file.path, from: root): _stripComments(file.readAsStringSync()),
  };

  test('the tree under test is not empty', () {
    expect(sources.keys, contains('lib/src/core/process_runner.dart'));
    expect(sources.keys, contains('bin/winbridge.dart'));
  });

  test('only ProcessRunner spawns processes', () {
    sources.forEach((path, code) {
      if (path == scanner || mayUseProcess.contains(path)) return;
      for (final forbidden in const [
        'Process.start',
        'Process.run',
        'Process.runSync',
        'Process.startSync',
      ]) {
        expect(
          code,
          isNot(contains(forbidden)),
          reason: '$path calls $forbidden directly; '
              'route it through ProcessRunner instead',
        );
      }
    });
  });

  test('nothing runs a shell', () {
    sources.forEach((path, code) {
      if (path == scanner) return;
      expect(
        code,
        isNot(contains('runInShell: true')),
        reason: '$path enables a shell',
      );
      for (final shell in const ['/bin/sh', '/bin/bash', 'sh -c', 'bash -c']) {
        expect(
          code,
          isNot(contains(shell)),
          reason: '$path references $shell',
        );
      }
    });
  });

  test('runInShell is decided in exactly one place', () {
    final mentions = [
      for (final entry in sources.entries)
        if (entry.key != scanner && entry.value.contains('runInShell'))
          entry.key,
    ];
    expect(mentions, mayUseProcess.toList());
  });
}

Iterable<File> _dartFiles(String root) sync* {
  for (final directory in const ['lib', 'bin', 'test']) {
    final source = Directory(p.join(root, directory));
    if (!source.existsSync()) continue;
    for (final entry in source.listSync(recursive: true)) {
      if (entry is File && entry.path.endsWith('.dart')) yield entry;
    }
  }
}

/// Drops comments so that prose describing the rules does not trip them.
String _stripComments(String source) {
  final withoutBlocks = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .map((line) {
        final index = line.indexOf('//');
        return index < 0 ? line : line.substring(0, index);
      })
      .join('\n');
}
