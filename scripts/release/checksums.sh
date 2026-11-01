#!/usr/bin/env bash
# Writes <dir>/SHA256SUMS over the nine Linux release files for <version>
# (x64 and arm64: tarball, .deb, .rpm and Arch package; plus the AUR
# PKGBUILD archive), and refuses to if any of them is missing: a release that
# quietly ships one architecture or one format is the failure this exists to
# prevent. Names in the file are bare file names, so `sha256sum -c SHA256SUMS`
# works from wherever the files are downloaded to.
#
# Usage: scripts/release/checksums.sh <version> <dir>

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <version> <dir>" >&2
  exit 2
fi

version="$1"
dir="$2"

files=(
  "winbridge-${version}-linux-x64.tar.gz"
  "winbridge_${version}-1_amd64.deb"
  "winbridge-${version}-linux-arm64.tar.gz"
  "winbridge_${version}-1_arm64.deb"
  "winbridge-${version}-1.x86_64.rpm"
  "winbridge-${version}-1.aarch64.rpm"
  "winbridge-${version}-1-x86_64.pkg.tar.zst"
  "winbridge-${version}-1-aarch64.pkg.tar.zst"
  "winbridge-bin-${version}-aur.tar.gz"
)

cd "$dir"
for file in "${files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "error: missing release file $file in $dir" >&2
    exit 1
  fi
done

sha256sum "${files[@]}" > SHA256SUMS
cat SHA256SUMS
sha256sum --check SHA256SUMS
