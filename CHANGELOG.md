# Changelog

## 0.5.0 - 2026-10-16

- Added: Linux arm64 builds. Every release now carries
  `winbridge-<version>-linux-arm64.tar.gz` and `winbridge_<version>-1_arm64.deb`
  next to the x64 files, built and tested on arm64 machines in CI, with one
  `SHA256SUMS` covering all four. The snap also builds for arm64.
- Added: on an arm64 host `winbridge doctor --install go|zig|msvc` downloads the
  arm64 build of Go, Zig or xwin (each pinned by checksum, never the x64 one),
  and `winbridge build` produces the same Windows x86-64 binaries an x64 host does.
- Changed: on an arm64 host the commands that need the managed Wine runtime
  (`run`, `prefix tricks`, `--dxvk`, `package`, and `recipe apply` for a recipe
  that has something to apply) stop immediately with an explanation, before any
  download or prefix. The managed Wine is an x86-64 build and no arm64 Wine that
  can run x86-64 Windows programs is available in a form WinBridge can pin.
  `WINBRIDGE_WINE` still points WinBridge at a Wine you provide. `doctor` and
  `report` say the runtime is unavailable.
- Added: classic-confinement snap packaging (`snap/snapcraft.yaml`, `packaging/SNAP.md`).
- Docs: the install snippet matches the tarball layout; the README and
  `docs/distribution.md` describe arm64 hosts and the arm64 release files.

## 0.4.0

Earlier releases are listed on the
[releases page](https://github.com/Dhiva-Labs/WinBridge/releases).
