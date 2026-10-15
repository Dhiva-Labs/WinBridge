#!/usr/bin/env bash
# Assembles the Linux release artifacts for the architecture this script runs
# on, from an already-compiled `winbridge` binary:
#
#   winbridge-<version>-linux-<x64|arm64>.tar.gz   (unpacks to one directory)
#   winbridge_<version>-1_<amd64|arm64>.deb
#
# The architecture comes from `dpkg --print-architecture`, never from a
# parameter, and is checked against what the binary actually is (`file`): a
# release asset named arm64 that holds an x86-64 binary is the failure this
# guards against. Both CI (every pull request) and the tag-driven release
# workflow call this, so the packaging that ships is the packaging that was
# tested.
#
# Usage: scripts/release/package-linux.sh <version> <binary> [output-dir]
#
# Run from anywhere; it reads LICENSE, README.md and debian/ from the checkout
# it lives in. Needs dpkg-deb, tar, gzip and file, all on a stock Ubuntu runner.

set -euo pipefail
umask 022

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <version> <binary> [output-dir]" >&2
  exit 2
fi

version="$1"
binary="$2"
out="${3:-.}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ ! -x "$binary" ]; then
  echo "error: $binary is not an executable file" >&2
  exit 1
fi

deb_arch="$(dpkg --print-architecture)"
case "$deb_arch" in
  amd64)
    slug="x64"
    elf_pattern="x86-64"
    ;;
  arm64)
    slug="arm64"
    elf_pattern="ARM aarch64"
    ;;
  *)
    echo "error: no release packaging for architecture '$deb_arch' (amd64 and arm64 only)" >&2
    exit 1
    ;;
esac

described="$(file -b "$binary")"
case "$described" in
  *"$elf_pattern"*) ;;
  *)
    echo "error: $binary is not a $deb_arch binary: $described" >&2
    exit 1
    ;;
esac
echo "binary: $described"

mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- tarball -----------------------------------------------------------------
stage="winbridge-${version}-linux-${slug}"
mkdir -p "$work/$stage"
install -m 0755 "$binary" "$work/$stage/winbridge"
install -m 0644 "$root/LICENSE" "$work/$stage/LICENSE"
install -m 0644 "$root/README.md" "$work/$stage/README.md"
tar -czf "$out/${stage}.tar.gz" -C "$work" "$stage"

# --- .deb --------------------------------------------------------------------
# Mirrors the structure of the winbridge_0.3.0-1_amd64.deb already on the
# releases page: /usr/bin/winbridge, /usr/share/doc/winbridge/copyright, and a
# control file carrying the same Depends/Recommends as debian/control (the PPA
# package). The two are built by different means (this is a hand-assembled
# `dpkg-deb`, not a `dh` build via debian/rules) but must describe the same
# package.
pkg="winbridge_${version}-1_${deb_arch}"
mkdir -p "$work/$pkg/usr/bin" "$work/$pkg/usr/share/doc/winbridge" "$work/$pkg/DEBIAN"
install -m 0755 "$binary" "$work/$pkg/usr/bin/winbridge"
install -m 0644 "$root/debian/copyright" "$work/$pkg/usr/share/doc/winbridge/copyright"
gzip -9n -c "$root/debian/changelog" > "$work/$pkg/usr/share/doc/winbridge/changelog.gz"
cat > "$work/$pkg/DEBIAN/control" <<CONTROL
Package: winbridge
Version: ${version}-1
Section: devel
Priority: optional
Architecture: ${deb_arch}
Maintainer: Dhiva Labs <dhivakar1010@gmail.com>
Homepage: https://github.com/Dhiva-Labs/WinBridge
Depends: libc6
Recommends: openssh-client, rsync, curl, xz-utils
Description: build and run Windows apps from Linux, without leaving Linux
 WinBridge cross-compiles Windows binaries from Go, Rust, .NET, C/C++ and
 Flutter projects and checks every artifact for a real Windows PE32+ header
 before calling a build a success. It also runs existing Windows programs
 through a managed Wine runtime it downloads and verifies itself, with an
 isolated prefix per app and optional DXVK for Direct3D-over-Vulkan
 rendering. No system Wine, no root, nothing to configure by hand.
CONTROL
dpkg-deb --build --root-owner-group "$work/$pkg" "$out/${pkg}.deb"

echo "wrote:"
echo "  $out/${stage}.tar.gz"
echo "  $out/${pkg}.deb"
