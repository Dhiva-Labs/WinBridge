#!/usr/bin/env bash
# Assembles and builds the winbridge PPA *source* package for dhiva-apps.
#
# Launchpad's build farm has no outbound network access and no Dart SDK, so
# this cannot be a normal "debian/rules compiles it" package. Instead this
# script compiles the binary locally (with the same analyze/test gates CI
# runs), copies debian/ into a clean scratch directory alongside it, and
# builds a "3.0 (native)" source package from *that* — not from the live
# repository tree. Only debian/, LICENSE and README.md ever end up in the
# tarball; the Dart source, tests and fixtures do not, because nothing on
# the builder ever compiles them. debian/rules just installs the binary this
# script already vendored — see the comment at its top for the reasoning,
# and docs/distribution.md for how this fits the rest of the release story.
#
# This never uploads anything. It prints the exact `dput` command for the
# PM (or whoever is doing the release) to run by hand once they are ready.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release/build-ppa-source.sh [--unsigned] [--skip-checks]

  --unsigned     Build with `debuild -S -us -uc` instead of `-sa`, for a
                 local dry run that needs no GPG key. The real release build
                 (the default) signs, and needs the maintainer's key
                 available.

  --skip-checks  Skip `dart analyze`/`dart test`. For proving the packaging
                 mechanics (this repo's debian/rules, debuild, dpkg-source)
                 in isolation while other, unrelated work elsewhere in the
                 tree is mid-edit and failing its own tests — NEVER for an
                 actual release. A release with a failing test suite is not
                 a release.
EOF
}

sign_flags=(-sa)
skip_checks=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) sign_flags=(-us -uc) ;;
    --skip-checks) skip_checks=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

for tool in dart debuild dpkg-parsechangelog; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

echo "==> dart pub get"
dart pub get

if [[ "$skip_checks" -eq 1 ]]; then
  echo "==> SKIPPING dart analyze / dart test (--skip-checks): this build does" >&2
  echo "    not prove the checked-out tree is releasable, only that the" >&2
  echo "    packaging mechanics work. Do not dput anything this produced." >&2
else
  # Scoped to lib/ and bin/ — what `dart compile exe` actually reaches — not
  # the whole repo: `dart analyze --fatal-infos` at the repo root also lints
  # every test/ directory, and this script has no business blocking a PPA
  # build on a lint warning in, say, another engineer's in-progress test
  # file that never ships in the compiled binary either way.
  echo "==> dart analyze --fatal-infos (lib/ bin/)"
  dart analyze lib bin --fatal-infos

  echo "==> dart test"
  dart test
fi

changelog_version="$(dpkg-parsechangelog -l debian/changelog -S Version)"
pubspec_version="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*//')"
# debian/changelog's version carries a `~nobleN` PPA revision the pubspec
# version never does (e.g. "0.4.0~noble1" vs "0.4.0") — compare only the
# part before the `~`.
changelog_upstream_version="${changelog_version%%~*}"
if [[ "$changelog_upstream_version" != "$pubspec_version" ]]; then
  echo "warning: debian/changelog is for winbridge $changelog_upstream_version" \
    "but pubspec.yaml says $pubspec_version." >&2
  echo "         Bumping one without the other means the binary this script" \
    "compiles will report a version the .dsc does not agree with. This is" \
    "expected before pubspec.yaml is bumped for a release still in" \
    "progress; it must not be true by the time this actually ships." >&2
fi

echo "==> dart compile exe (winbridge $pubspec_version, this machine's toolchain)"
compiled="$(mktemp -d)/winbridge"
dart compile exe bin/winbridge.dart -o "$compiled"
chmod +x "$compiled"
"$compiled" --version

stage_parent="$(mktemp -d)"
stage="$stage_parent/winbridge-$changelog_version"
mkdir -p "$stage/debian"
cp -a debian/. "$stage/debian/"
mkdir -p "$stage/debian/vendor"
cp "$compiled" "$stage/debian/vendor/winbridge"
chmod 0755 "$stage/debian/vendor/winbridge"
cp LICENSE "$stage/LICENSE"
cp README.md "$stage/README.md"

echo "==> source tree staged at $stage"
echo "    (debian/ + LICENSE + README.md + the vendored binary — nothing else)"

echo "==> debuild -S ${sign_flags[*]}"
(cd "$stage" && debuild -S "${sign_flags[@]}")

dsc="$stage_parent/winbridge_${changelog_version}.dsc"
changes="$stage_parent/winbridge_${changelog_version}_source.changes"

echo
echo "==> built:"
ls -la "$stage_parent"/winbridge_"${changelog_version}"* 2>/dev/null || true

echo
if [[ -f "$dsc" ]]; then
  echo "Source package: $dsc"
fi

echo
echo "This script never uploads. To publish once you are ready:"
echo
if [[ -f "$changes" ]]; then
  echo "  dput dhiva-apps $changes"
else
  echo "  dput dhiva-apps $stage_parent/winbridge_${changelog_version}_source.changes"
fi
echo
echo "('dhiva-apps' is the dput host alias in ~/.dput.cf — fqdn" \
  "ppa.launchpad.net, incoming ~dhiva-labs/ubuntu/apps/ — the same one" \
  "every other dhiva-apps package in ~/dhiva-labs/*.upload was uploaded to.)"
