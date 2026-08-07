import '../run/asset_cache.dart';

/// Something `winbridge doctor --install <id>` can fetch.
///
/// Every entry is a [PinnedAsset], so the download rules are the same ones
/// everything else in WinBridge obeys: exact version, checksum verified before
/// anything is unpacked, stamped, and never used unverified.
///
/// [downloadSize] is shown *before* the download starts. Some of these are
/// large enough that starting one unasked would be rude, and one of them
/// (`msvc`) also carries a licence the user has to accept — so nothing here is
/// ever installed implicitly by a build.
class InstallableComponent {
  const InstallableComponent({
    required this.id,
    required this.summary,
    required this.downloadSize,
    required this.asset,
    this.licenceNote,
    this.followUp,
    this.probeBinary,
  });

  /// What the user types: `winbridge doctor --install go`.
  final String id;

  final String summary;

  /// Human-readable, e.g. `67 MB`. Approximate on purpose — it is there to let
  /// someone decide, not to be exact.
  final String downloadSize;

  final PinnedAsset asset;

  /// Shown before installing when the component carries third-party terms.
  final String? licenceNote;

  /// What the user still has to do afterwards, when the download alone is not
  /// the whole job.
  final String? followUp;

  /// An executable name that means "this already works here, just not from a
  /// copy WinBridge installed". Null when there is nothing sensible to probe.
  final String? probeBinary;
}

/// Pinned 2026-08. Each hash was computed from the downloaded bytes; `go` and
/// `zig` additionally match the checksums their own projects publish, and
/// `xwin` matches the `.sha256` beside its release asset.
const goToolchain = PinnedAsset(
  name: 'go',
  version: '1.26.5',
  url: 'https://go.dev/dl/go1.26.5.linux-amd64.tar.gz',
  sha256: '5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053',
  archiveTopLevel: 'go',
  root: AssetRoot.toolchains,
);

const zigToolchain = PinnedAsset(
  name: 'zig',
  version: '0.16.0',
  url: 'https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz',
  sha256: '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00',
  archiveTopLevel: 'zig-x86_64-linux-0.16.0',
  root: AssetRoot.toolchains,
  // zig ships its binary at the archive root; ToolResolver only reads bin/.
  exposeBinaries: ['zig'],
);

/// The official NSIS distribution zip. Windows binaries on purpose: WinBridge
/// runs `makensis.exe` under its own managed Wine rather than needing a Linux
/// NSIS build, which is the same engine `winbridge run` uses.
const nsisDistribution = PinnedAsset(
  name: 'nsis-3.12',
  version: '3.12',
  url: 'https://sourceforge.net/projects/nsis/files/NSIS%203/3.12/'
      'nsis-3.12.zip/download',
  sha256: '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f',
  archiveTopLevel: 'nsis-3.12',
  archiveFormat: ArchiveFormat.zip,
);

/// The xwin tool itself — a few megabytes. It is what *downloads* the Microsoft
/// CRT and Windows SDK, which are gigabytes and are not pinned here: they come
/// from Microsoft's own servers, under Microsoft's licence, at the version
/// xwin resolves. See `MsvcToolchain` for why that split exists.
const xwinTool = PinnedAsset(
  name: 'xwin-0.9.0',
  version: '0.9.0',
  url: 'https://github.com/Jake-Shadle/xwin/releases/download/0.9.0/'
      'xwin-0.9.0-x86_64-unknown-linux-musl.tar.gz',
  sha256: '31e1033f30608ba6b821d17f1461042bd54c23424813c9b4e9ae15b6d32fa4cd',
  archiveTopLevel: 'xwin-0.9.0-x86_64-unknown-linux-musl',
);

const installableComponents = <InstallableComponent>[
  InstallableComponent(
    id: 'go',
    summary: 'Go toolchain, for cross-compiling Go projects',
    downloadSize: '67 MB',
    asset: goToolchain,
    probeBinary: 'go',
  ),
  InstallableComponent(
    id: 'zig',
    summary: 'Zig, used as the C/C++ cross-compiler',
    downloadSize: '56 MB',
    asset: zigToolchain,
    probeBinary: 'zig',
  ),
  InstallableComponent(
    id: 'nsis',
    summary: 'NSIS, to build Windows installers with `winbridge package`',
    downloadSize: '2 MB',
    asset: nsisDistribution,
  ),
  InstallableComponent(
    id: 'msvc',
    summary: 'xwin, plus the Microsoft CRT and Windows SDK it downloads',
    downloadSize: '3 MB now, then ~1-2 GB of Microsoft headers and libraries',
    asset: xwinTool,
    licenceNote:
        'The CRT and Windows SDK come from Microsoft and are covered by the '
        'Microsoft Software License Terms for Visual Studio. Installing this '
        'passes --accept-license to xwin on your behalf, which is you '
        'accepting those terms. Read them first if that matters to you: '
        'https://visualstudio.microsoft.com/license-terms/',
    followUp:
        'Linking also needs lld-link, which WinBridge does not download — see '
        '`winbridge doctor` and docs/packaging.md.',
  ),
];

InstallableComponent? findComponent(String id) {
  for (final component in installableComponents) {
    if (component.id == id) return component;
  }
  return null;
}
