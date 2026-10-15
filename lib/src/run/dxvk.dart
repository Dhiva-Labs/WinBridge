import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/host_arch.dart';
import '../core/output.dart';
import '../core/process_runner.dart';
import '../core/tool_resolver.dart';
import 'asset_cache.dart';
import 'prefix.dart';

/// The exact [DXVK](https://github.com/doitsujin/dxvk) release WinBridge
/// installs. DXVK replaces Wine's Direct3D implementation with one that
/// translates to Vulkan, which is markedly faster for 3D applications.
const pinnedDxvk = PinnedAsset(
  name: 'dxvk-3.0.2',
  version: '3.0.2',
  url: 'https://github.com/doitsujin/dxvk/releases/download/v3.0.2/'
      'dxvk-3.0.2.tar.gz',
  sha256: '9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2',
  archiveTopLevel: 'dxvk-3.0.2',
);

/// The DLLs DXVK provides, and therefore the ones Wine must be told to load
/// from the prefix rather than use its own built-in versions.
const dxvkDlls = ['d3d8', 'd3d9', 'd3d10core', 'd3d11', 'dxgi'];

/// Records which DXVK version a prefix has, so later runs can turn the
/// overrides on without being asked again.
const dxvkMarkerFile = '.winbridge-dxvk';

/// Installs DXVK into a Wine prefix and works out the environment a
/// DXVK-enabled run needs.
class DxvkInstaller {
  DxvkInstaller({
    required this.config,
    required this.tools,
    required this.runner,
    required this.output,
    this.asset = pinnedDxvk,
  }) : _cache = AssetCache(
          config: config,
          tools: tools,
          runner: runner,
          output: output,
        );

  final WinBridgeConfig config;
  final ToolResolver tools;
  final ProcessRunner runner;
  final Output output;
  final PinnedAsset asset;
  final AssetCache _cache;

  /// The DXVK version installed in [prefix], or null if there is none.
  static String? installedVersion(AppPrefix prefix) {
    final marker = File(p.join(prefix.path, dxvkMarkerFile));
    if (!marker.existsSync()) return null;
    final version = marker.readAsStringSync().trim();
    return version.isEmpty ? null : version;
  }

  static bool isEnabledFor(AppPrefix prefix) =>
      installedVersion(prefix) != null;

  /// Copies the DXVK DLLs into [prefix] and marks it.
  ///
  /// x64 DLLs go to `system32` and x32 to `syswow64`, which is the layout Wine
  /// uses on a 64-bit prefix — `system32` holds the 64-bit DLLs there, not the
  /// 32-bit ones the name suggests. Our pinned Wine is a wow64 build, so both
  /// halves are worth installing even for a 64-bit app: a 32-bit installer or
  /// launcher shipped alongside it will find them.
  Future<void> installInto(AppPrefix prefix) async {
    final source = await _cache.ensure(asset);

    final system32 = Directory(
      p.join(prefix.path, 'drive_c', 'windows', 'system32'),
    );
    final syswow64 = Directory(
      p.join(prefix.path, 'drive_c', 'windows', 'syswow64'),
    );
    if (!system32.existsSync()) {
      throw BuildFailure(
        'the prefix ${prefix.name} has no Windows system directory yet',
        details: 'run the app once without --dxvk so Wine can create it, '
            'then try again',
      );
    }

    var copied = 0;
    copied += _copyArch(p.join(source, 'x64'), system32);
    if (syswow64.existsSync()) {
      copied += _copyArch(p.join(source, 'x32'), syswow64);
    }
    if (copied == 0) {
      throw BuildFailure(
        'the DXVK archive had no DLLs to install',
        details: source,
      );
    }

    File(p.join(prefix.path, dxvkMarkerFile))
        .writeAsStringSync('${asset.version}\n');
    output.detail('installed DXVK ${asset.version} into ${prefix.path}');
  }

  int _copyArch(String sourceDirectory, Directory destination) {
    final source = Directory(sourceDirectory);
    if (!source.existsSync()) return 0;
    var copied = 0;
    for (final dll in dxvkDlls) {
      final file = File(p.join(sourceDirectory, '$dll.dll'));
      if (!file.existsSync()) continue;
      file.copySync(p.join(destination.path, '$dll.dll'));
      copied++;
    }
    return copied;
  }

  /// Removes the marker so later runs stop setting the overrides.
  ///
  /// The DLLs are deliberately left in place: putting Wine's originals back
  /// would mean shipping copies of them, and the override is what actually
  /// decides which implementation loads. A prefix that should be truly clean
  /// is one `rm -rf` away, which is the documented reset.
  static void disableFor(AppPrefix prefix) {
    final marker = File(p.join(prefix.path, dxvkMarkerFile));
    if (marker.existsSync()) marker.deleteSync();
  }
}

/// The `WINEDLLOVERRIDES` value for a DXVK-enabled run.
///
/// `=n` means "native", i.e. the DLL sitting in the prefix — the DXVK one —
/// rather than Wine's built-in Direct3D. Any value the user already exported
/// is appended *after* ours: Wine reads the list left to right and a later
/// entry wins, so an explicit `WINEDLLOVERRIDES=d3d11=b` still takes effect
/// and someone debugging can always override us.
String dxvkDllOverrides({String? existing}) {
  final ours = '${dxvkDlls.join(',')}=n';
  final theirs = existing?.trim();
  if (theirs == null || theirs.isEmpty) return ours;
  return '$ours;$theirs';
}

/// Whether this machine looks able to run Vulkan at all.
///
/// Deliberately shallow and vendor-neutral: this reports whether the Vulkan
/// loader and tools are present, not which GPU is installed or whose driver is
/// in use. Anything more would be guessing on the user's behalf.
class VulkanCheck {
  const VulkanCheck({required this.loaderPath, required this.vulkaninfoPath});

  final String? loaderPath;
  final String? vulkaninfoPath;

  bool get looksAvailable => loaderPath != null || vulkaninfoPath != null;

  static const _loaderNames = ['libvulkan.so.1', 'libvulkan.so'];

  /// Where a distribution puts the loader. Debian-style multiarch directories
  /// are named for the CPU, so an arm64 machine keeps it under
  /// `aarch64-linux-gnu`, not `x86_64-linux-gnu`. With no [arch] both are
  /// searched, which is the right answer for a CPU WinBridge has no builds for.
  static List<String> loaderDirectories(HostArch? arch) {
    final triplets = switch (arch) {
      HostArch.x64 => ['x86_64-linux-gnu'],
      HostArch.arm64 => ['aarch64-linux-gnu'],
      null => ['x86_64-linux-gnu', 'aarch64-linux-gnu'],
    };
    return [
      for (final triplet in triplets) '/usr/lib/$triplet',
      '/usr/lib64',
      '/usr/lib',
      for (final triplet in triplets) '/lib/$triplet',
      '/usr/local/lib',
    ];
  }

  static VulkanCheck detect(ToolResolver tools, {HostArch? arch}) {
    String? loader;
    for (final directory in loaderDirectories(arch)) {
      for (final name in _loaderNames) {
        final candidate = p.join(directory, name);
        if (FileSystemEntity.typeSync(candidate) !=
            FileSystemEntityType.notFound) {
          loader = candidate;
          break;
        }
      }
      if (loader != null) break;
    }
    return VulkanCheck(
      loaderPath: loader,
      vulkaninfoPath: tools.resolve('vulkaninfo')?.path,
    );
  }

  /// What to tell someone who asked for DXVK on a machine without Vulkan.
  static const missingAdvice =
      'DXVK renders through Vulkan, and no Vulkan loader was found on this '
      'machine. Install your distribution\'s Vulkan loader and the driver '
      'package for your graphics hardware (on Debian/Ubuntu that is usually '
      '`libvulkan1` plus a mesa or vendor driver package), then try again. '
      '`winbridge run --no-dxvk` runs without it.';
}
