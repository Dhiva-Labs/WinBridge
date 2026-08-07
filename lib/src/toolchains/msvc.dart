import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/build.dart';
import '../core/config.dart';
import '../core/toolchain.dart';
import '../detect/project.dart';
import 'c.dart' show discoverCSources, hasCxxSources;

/// Where `winbridge doctor --install msvc` puts the Microsoft CRT and Windows
/// SDK that xwin downloads.
String? xwinSplatRoot(WinBridgeConfig config) {
  final cache = config.cacheRoot;
  return cache == null ? null : p.join(cache, 'xwin');
}

/// The subdirectories xwin's default splat produces, and which ones a compile
/// and a link each need.
class XwinSplat {
  const XwinSplat(this.root);

  final String root;

  List<String> get includeDirectories => [
        p.join(root, 'crt', 'include'),
        p.join(root, 'sdk', 'include', 'ucrt'),
        p.join(root, 'sdk', 'include', 'um'),
        p.join(root, 'sdk', 'include', 'shared'),
      ];

  List<String> get libraryDirectories => [
        p.join(root, 'crt', 'lib', 'x86_64'),
        p.join(root, 'sdk', 'lib', 'um', 'x86_64'),
        p.join(root, 'sdk', 'lib', 'ucrt', 'x86_64'),
      ];

  /// A splat is usable when the CRT headers and libraries are both there.
  /// Checking one directory would pass a half-finished download.
  bool get isPresent =>
      Directory(p.join(root, 'crt', 'include')).existsSync() &&
      Directory(p.join(root, 'crt', 'lib', 'x86_64')).existsSync() &&
      Directory(p.join(root, 'sdk', 'include', 'ucrt')).existsSync();
}

/// Names a Windows-targeting clang may be installed under. Distributions often
/// ship only the versioned form.
const clangCandidates = ['clang-cl', 'clang', 'clang-18', 'clang-19'];

/// The MSVC linker, in the order worth trying. `lld-link` is the real name;
/// `ld.lld` and `lld` are the same binary under names some packages use.
const lldLinkCandidates = ['lld-link', 'lld-link-18', 'lld-link-19', 'ld.lld',
    'lld'];

/// Builds C/C++ for the genuine MSVC ABI — `x86_64-pc-windows-msvc` — using
/// clang against Microsoft's own headers and import libraries.
///
/// This exists for code that cannot use the MinGW ABI: anything linking a
/// vendor library built with MSVC, or using MSVC-specific extensions. It is
/// *not* the default. `CToolchain` (zig cc / MinGW) is registered first and
/// keeps the cheap path, per the plan's "cheap path first" principle — reaching
/// this one takes `--toolchain msvc`, because it costs a multi-gigabyte
/// download of Microsoft's SDK and acceptance of Microsoft's licence.
class MsvcToolchain implements Toolchain {
  const MsvcToolchain();

  @override
  String get id => 'msvc';

  @override
  String get description =>
      'compiles C/C++ for the MSVC ABI via clang-cl and the Windows SDK';

  /// Claims the same projects as the MinGW/zig adapter. Registration order is
  /// what keeps that one the default; this is only reached by name.
  @override
  bool canHandle(Project project) => project.type == ProjectType.c;

  @override
  List<ToolRequirement> requirements() => const [
        ToolRequirement(
          tool: 'clang',
          alternatives: ['clang-cl', 'clang-18', 'clang-19'],
          reason: 'compiles C/C++ for the MSVC ABI',
        ),
        ToolRequirement(
          tool: 'lld-link',
          alternatives: ['lld-link-18', 'lld-link-19', 'ld.lld', 'lld'],
          reason: 'links MSVC-ABI objects (Debian/Ubuntu: the `lld` package)',
        ),
        ToolRequirement(
          tool: 'llvm-rc',
          alternatives: ['llvm-rc-18', 'llvm-rc-19'],
          reason: 'compiles .rc resource scripts, if a project has any',
          optional: true,
        ),
      ];

  @override
  Future<BuildResult> build(BuildRequest request) async {
    final splatRoot = xwinSplatRoot(WinBridgeConfig());
    if (splatRoot == null) {
      return const BuildResult.failure(
        'cannot locate the Windows SDK cache',
        details: 'no HOME or XDG_CACHE_HOME in the environment',
      );
    }
    final splat = XwinSplat(splatRoot);
    if (!splat.isPresent) {
      return BuildResult.failure(
        'the Microsoft CRT and Windows SDK are not installed',
        details: 'The MSVC ABI needs Microsoft\'s own headers and import '
            'libraries, which WinBridge does not download unless you ask:\n\n'
            '  winbridge doctor --install msvc\n\n'
            'That is roughly 1-2 GB and requires accepting Microsoft\'s '
            'licence terms. To build without it, use the default toolchain '
            '(MinGW ABI via zig cc): drop `--toolchain msvc`.\n'
            'Expected the splat at $splatRoot',
      );
    }

    final clang = request.tools.requireAny(
      clangCandidates,
      reason: 'compiles C/C++ for the MSVC ABI',
    );
    final linker = request.tools.resolveAny(lldLinkCandidates);
    if (linker == null) {
      return BuildResult.failure(
        'no MSVC-compatible linker found',
        details: 'The MSVC ABI is linked by lld-link, which WinBridge does '
            'not download: it is one binary, and its only official '
            'distribution is a ~1.5 GB LLVM toolchain archive. Install it '
            'from your distribution instead — on Debian and Ubuntu that is '
            '`lld`, which also provides ld.lld.\n'
            'Looked for: ${lldLinkCandidates.join(', ')}',
      );
    }

    final sources = discoverCSources(request.project.root);
    if (sources.isEmpty) {
      return const BuildResult.failure(
        'no direct C/C++ sources found',
        details: 'the MSVC adapter compiles top-level and src/ *.c/*.cpp '
            'files directly; it does not drive CMake or MSBuild',
      );
    }

    final exe = p.join(request.outputDirectory, '${request.project.name}.exe');
    final objectDirectory = p.join(request.cacheDirectory, 'obj');
    Directory(objectDirectory).createSync(recursive: true);

    final result = await request.runner.run(
      clang.path,
      msvcArguments(
        splat: splat,
        sources: sources,
        outputExe: exe,
        objectDirectory: objectDirectory,
        linker: linker.path,
        release: request.mode.isRelease,
        cxx: hasCxxSources(sources),
        extraArguments: request.extraArguments,
      ),
      workingDirectory: request.project.root,
    );

    if (!result.ok) {
      return BuildResult.failure(
        'clang-cl build failed',
        details: result.diagnostics,
      );
    }
    return BuildResult.success(
      artifacts: [exe],
      summary: 'clang-cl, x86_64-pc-windows-msvc',
      duration: result.duration,
    );
  }
}

/// The exact argument vector an MSVC-ABI build uses.
///
/// Split out because it is the part worth pinning down in tests: this machine
/// has no Windows SDK to link against, so the command WinBridge *constructs* is
/// what can be verified here, and it is verified precisely.
List<String> msvcArguments({
  required XwinSplat splat,
  required List<String> sources,
  required String outputExe,
  required String objectDirectory,
  required String linker,
  required bool release,
  required bool cxx,
  List<String> extraArguments = const [],
}) {
  return [
    '--driver-mode=cl',
    '/nologo',
    '--target=x86_64-pc-windows-msvc',
    // clang picks the linker by name; point it at the one we resolved rather
    // than hoping the right one is on PATH under the right spelling.
    '--ld-path=$linker',
    if (cxx) '/EHsc',
    if (release) '/O2' else '/Od',
    // /imsvc rather than /I: these are system headers, and Microsoft's carry
    // warnings that are not the user's to fix.
    for (final include in splat.includeDirectories) ...['/imsvc', include],
    // Trailing separator is what tells cl.exe this is a directory.
    '/Fo$objectDirectory${p.separator}',
    ...extraArguments,
    ...sources,
    '/link',
    for (final library in splat.libraryDirectories) '/libpath:$library',
    '/out:$outputExe',
  ];
}
