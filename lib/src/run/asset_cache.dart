import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';

/// Something WinBridge downloads on the user's behalf, pinned to an exact
/// upstream build by checksum.
///
/// Every third-party component the `run` path manages — the Wine runtime,
/// DXVK, winetricks — is one of these, so they all get the same treatment: the
/// bytes are checked before they are unpacked or executed, and a copy that was
/// never checked is never used.
class PinnedAsset {
  const PinnedAsset({
    required this.name,
    required this.version,
    required this.url,
    required this.sha256,
    this.archiveTopLevel,
    this.fileName,
    this.executable = false,
  });

  /// Directory name under the cache root. Carries the version, so a new pin
  /// installs beside the old one instead of overwriting something in use.
  final String name;

  final String version;
  final String url;

  /// Lowercase hex, verified before the download is unpacked or run.
  final String sha256;

  /// For a tar archive: the single directory it unpacks to. Null for a plain
  /// file download.
  final String? archiveTopLevel;

  /// For a plain file: what to call it on disk.
  final String? fileName;

  /// Whether a plain file needs its execute bit set.
  final bool executable;

  bool get isArchive => archiveTopLevel != null;
}

/// Downloads, verifies and caches [PinnedAsset]s under `~/.cache/winbridge/`.
///
/// The invariant every caller relies on: a path handed back by [locate] or
/// [ensure] has had its bytes checked against the pin. That is enforced by a
/// stamp file written *after* verification and *before* the directory is moved
/// to its final name, so an interrupted install, a partial extraction, or a
/// directory someone dropped in by hand is ignored rather than used.
class AssetCache {
  AssetCache({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
  });

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;

  /// Written after a successful verified install. Its presence *and* contents
  /// are what make a cached asset usable.
  static const stampFileName = '.winbridge-verified';

  /// Where [asset] lives once installed, or null with no cache to work from.
  String? directoryFor(PinnedAsset asset) {
    final root = config.managedRuntimeRoot;
    return root == null ? null : p.join(root, asset.name);
  }

  /// The payload path inside an installed asset: the directory for an archive,
  /// the file itself for a plain download.
  String? payloadFor(PinnedAsset asset) {
    final directory = directoryFor(asset);
    if (directory == null) return null;
    return asset.isArchive
        ? directory
        : p.join(directory, asset.fileName ?? asset.name);
  }

  /// Whether [asset] is present *and* carries the stamp for this exact pin.
  bool isInstalled(PinnedAsset asset) {
    final directory = directoryFor(asset);
    if (directory == null) return false;
    final stamp = File(p.join(directory, stampFileName));
    if (!stamp.existsSync()) return false;
    if (!stamp.readAsStringSync().contains(asset.sha256)) return false;
    final payload = payloadFor(asset)!;
    return asset.isArchive
        ? Directory(payload).existsSync()
        : File(payload).existsSync();
  }

  /// The installed payload path, installing first if it is not there yet.
  Future<String> ensure(PinnedAsset asset) async {
    if (!isInstalled(asset)) await install(asset);
    final payload = payloadFor(asset);
    if (payload == null) {
      throw const BuildFailure(
        'cannot work out where to cache downloads',
        details: 'no HOME or XDG_CACHE_HOME in the environment',
      );
    }
    return payload;
  }

  /// Downloads and verifies [asset], replacing any existing copy.
  ///
  /// The checksum is checked before anything is unpacked or made executable —
  /// a mismatched download is deleted, never opened. Work happens in a scratch
  /// directory beside the destination and is published with a single rename,
  /// which is only atomic within one filesystem, hence "beside".
  Future<void> install(PinnedAsset asset) async {
    final root = config.managedRuntimeRoot;
    final target = directoryFor(asset);
    if (root == null || target == null) {
      throw const BuildFailure('no cache directory to download into');
    }

    final curl =
        tools.requirePath('curl', reason: 'downloads ${asset.name}');
    final sha256sum =
        tools.requirePath('sha256sum', reason: 'verifies ${asset.name}');

    Directory(root).createSync(recursive: true);
    final scratch = Directory(p.join(root, '.install-${asset.name}-$pid'));
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    scratch.createSync(recursive: true);

    try {
      final download =
          p.join(scratch.path, asset.isArchive ? 'archive' : 'payload');
      output.detail('downloading ${asset.url}');
      final fetched = await runner.run(curl, [
        '-fL',
        '--silent',
        '--show-error',
        '--retry', '3',
        '--connect-timeout', '20',
        '-o', download,
        asset.url,
      ]);
      if (!fetched.ok) {
        throw BuildFailure(
          'could not download ${asset.name}',
          details: '${asset.url}\n${fetched.diagnostics}'.trim(),
        );
      }

      await _verify(sha256sum, download, asset);

      final Directory staged;
      if (asset.isArchive) {
        final unpackDir = Directory(p.join(scratch.path, 'unpacked'))
          ..createSync();
        final tar = tools.requirePath('tar', reason: 'unpacks ${asset.name}');
        final unpacked =
            await runner.run(tar, ['-xf', download, '-C', unpackDir.path]);
        if (!unpacked.ok) {
          throw BuildFailure(
            'could not unpack ${asset.name}',
            details: unpacked.diagnostics,
          );
        }
        staged = Directory(p.join(unpackDir.path, asset.archiveTopLevel!));
        if (!staged.existsSync()) {
          throw BuildFailure(
            'the ${asset.name} archive did not contain '
            '${asset.archiveTopLevel}/',
            details: 'downloaded from ${asset.url}',
          );
        }
      } else {
        staged = Directory(p.join(scratch.path, 'staged'))..createSync();
        final destination = p.join(staged.path, asset.fileName ?? asset.name);
        File(download).renameSync(destination);
        if (asset.executable) {
          // Only after the checksum passed: nothing unverified is ever made
          // runnable.
          final chmod =
              tools.requirePath('chmod', reason: 'installs ${asset.name}');
          final marked = await runner.run(chmod, ['+x', destination]);
          if (!marked.ok) {
            throw BuildFailure(
              'could not make ${asset.name} executable',
              details: marked.diagnostics,
            );
          }
        }
      }

      // Stamp before publishing, so the payload is never visible at its final
      // path without the proof that it was verified.
      File(p.join(staged.path, stampFileName))
          .writeAsStringSync('${asset.name}\n${asset.sha256}\n');

      final destination = Directory(target);
      if (destination.existsSync()) destination.deleteSync(recursive: true);
      staged.renameSync(target);
      output.detail('installed $target');
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  Future<void> _verify(
    String sha256sum,
    String path,
    PinnedAsset asset,
  ) async {
    final result = await runner.run(sha256sum, [path]);
    final actual = result.stdout.trim().split(RegExp(r'\s+')).firstOrNull ?? '';
    if (!result.ok || actual.isEmpty) {
      _discard(path);
      throw BuildFailure(
        'could not checksum the downloaded ${asset.name}',
        details: result.diagnostics,
      );
    }
    if (actual.toLowerCase() != asset.sha256.toLowerCase()) {
      _discard(path);
      throw BuildFailure(
        'the downloaded ${asset.name} does not match its expected checksum',
        details: 'expected ${asset.sha256}\n'
            'got      ${actual.toLowerCase()}\n'
            'from     ${asset.url}\n'
            'The download was discarded and nothing was unpacked.',
      );
    }
    output.detail('checksum verified: $actual');
  }

  static void _discard(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}
