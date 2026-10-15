import 'dart:ffi' show Abi;

/// The CPU architecture of the machine WinBridge itself is running on.
///
/// Not to be confused with `TargetArch`, which is the architecture of the
/// *Windows* binary being built. A Linux arm64 laptop can cross-compile a
/// windows-x64 program: the host arch decides which compiler downloads and
/// which Wine builds are usable, the target arch decides what comes out.
enum HostArch {
  x64(slug: 'x64', machine: 'x86_64', debian: 'amd64'),
  arm64(slug: 'arm64', machine: 'aarch64', debian: 'arm64');

  const HostArch({
    required this.slug,
    required this.machine,
    required this.debian,
  });

  /// The name release assets use: `winbridge-<v>-linux-<slug>.tar.gz`.
  final String slug;

  /// What `uname -m` prints, and the spelling zig, xwin and rustc use.
  final String machine;

  /// What `dpkg --print-architecture` prints.
  final String debian;

  /// The architecture this process is running on, or null for a CPU WinBridge
  /// has no builds for (32-bit ARM, RISC-V, ...). Callers decide what null
  /// means; for downloads it means "nothing to offer", never "assume x64".
  static HostArch? detect() => fromAbi(Abi.current());

  /// [detect], but for an explicit [Abi]. Separate so the mapping is testable
  /// on a machine that is not the one being described.
  static HostArch? fromAbi(Abi abi) {
    if (abi == Abi.linuxX64) return HostArch.x64;
    if (abi == Abi.linuxArm64) return HostArch.arm64;
    return null;
  }

  /// Parses any of the spellings people and tools use for these two
  /// architectures: `x64`, `x86_64`, `amd64`, `arm64`, `aarch64`.
  static HostArch? parse(String value) {
    switch (value.trim().toLowerCase()) {
      case 'x64' || 'x86_64' || 'x86-64' || 'amd64':
        return HostArch.x64;
      case 'arm64' || 'aarch64':
        return HostArch.arm64;
    }
    return null;
  }

  @override
  String toString() => slug;
}
