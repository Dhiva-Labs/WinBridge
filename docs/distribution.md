# Distribution

Every channel WinBridge ships through, how a release reaches each one, and
how a version bump is meant to flow from `pubspec.yaml` to something a user
can install. If a channel's status here is "untested" or "manual", that is
the actual state, not a formality — this document says so plainly rather
than implying more automation exists than does.

## The channels

| Channel | What it is | Built by | Status |
| --- | --- | --- | --- |
| GitHub release tarball | `winbridge-<ver>-linux-x64.tar.gz` — the binary plus `LICENSE`/`README.md` | `.github/workflows/release.yml`, on every `vX.Y.Z` tag push | Automated |
| GitHub release `.deb` | `winbridge_<ver>-1_amd64.deb` — installs to `/usr/bin/winbridge` | Same workflow, same tag push | Automated |
| `dhiva-apps` PPA | Ubuntu Noble source package, built by Launchpad's own build farm from what `dput` uploads | `debian/` + `scripts/release/build-ppa-source.sh`, run by hand | Source package builds and installs correctly locally (see below); **upload is a manual, deliberate step — nothing in this repository ever runs `dput`** |
| Flatpak | `io.github.dhiva_labs.WinBridge`, from `packaging/flatpak/` | `flatpak-builder`, run by hand (or future CI) | **Manifest only — untested on this machine, no `flatpak-builder` installed here.** See `packaging/flatpak/README.md` |
| Snap | `winbridge`, classic confinement, from `snap/snapcraft.yaml` | `snapcraft pack --use-lxd`, run by hand | Built and tested locally; **not yet registered or uploaded**, and classic needs a Snap Store forum approval first. See `packaging/SNAP.md` |

`winbridge doctor`/`winbridge report` and everything else the CLI does are
identical regardless of which channel installed it; nothing about the binary
itself differs between channels, only how it arrived.

## GitHub release: tarball and `.deb`

Both come from one workflow, `.github/workflows/release.yml`, triggered only
by pushing a tag matching `v*` (e.g. `v0.4.0`). In order:

1. **The tag must match `pubspec.yaml`'s version, or the workflow fails
   immediately** with a message naming both values — before `dart pub get`,
   before anything else runs. A release can never ship a binary whose
   `--version` output disagrees with the git tag that produced it, and the
   cheapest place to catch that is before spending any CI time on it.
2. `dart analyze --fatal-infos` and `dart test` — a failing suite means no
   release. There is no step after this that can undo a bad build once
   assets are uploaded, so nothing after it runs unless both pass.
3. `dart compile exe`, and a second check that the freshly compiled
   binary's own `--version` output agrees with the tag (belt and braces:
   the first check caught a human forgetting to bump `pubspec.yaml`, this
   one would catch the compiler somehow producing something else).
4. The tarball and `.deb` are assembled (see "Mirroring the release `.deb`
   structure" below) and `SHA256SUMS` is generated over both.
5. `gh release create` publishes the tag as a GitHub release with all three
   files attached. `gh` ships preinstalled on GitHub-hosted runners, so this
   needs no extra pinned action for the release step itself — only
   `actions/checkout` and `dart-lang/setup-dart` are pinned actions, and
   both are pinned to the exact same commit SHAs `ci.yml` already uses.

`permissions: contents: write` is granted at the job level, not the
workflow level — the same reasoning `ci.yml`'s comment gives for staying
read-only applies here in reverse: scoping the grant to the one job that
needs it means a step added to a different job later does not inherit
write access by accident.

## The PPA (`dhiva-apps`)

### Why this package is shaped the way it is

Launchpad's PPA build farm has no outbound network access and no Dart SDK.
A normal Debian package's `debian/rules` compiles from source on the
builder; that is not possible here. The pattern this package follows
instead — established by this organization's other PPA packages, read
(read-only) from `~/dhiva-labs/secureshellgo_1.4.3~noble1.dsc` and its
`.tar.xz` while designing this one — is: **compile locally, vendor the
compiled result inside the source package, and have `debian/rules` install
it rather than build it.**

SecureShellGo's version of this problem is bigger than WinBridge's: it is a
Flutter app, so its `debian/rules` vendors the entire Flutter SDK and pub
cache as tarballs under `packaging/vendor/`, extracts them at package-build
time, and runs a real (offline) `flutter build linux --release` on the
builder. WinBridge's version is smaller because `dart compile exe` produces
one self-contained ELF binary with no further build step to hide from the
network — there is nothing to vendor *and then build*, only something to
vendor and then copy into place. Concretely:

- **`debian/vendor/winbridge`** is where the compiled binary lives inside
  the source package. It is never present in this git repository — only
  `scripts/release/build-ppa-source.sh` ever creates it, inside a scratch
  copy of `debian/` it stages for exactly one build.
- **`debian/rules`** has no real build step. `override_dh_auto_build`
  checks the vendored binary is there (and fails with an explanation if
  it isn't, rather than a debhelper stack trace); `override_dh_auto_install`
  copies it to `/usr/bin/winbridge`.
- **`debian/source/format` is `3.0 (native)`** — the same format
  SecureShellGo uses, and for the same underlying reason: there is no
  meaningful "upstream tarball vs. Debian packaging" split to preserve when
  the entire "source" a builder needs is the packaging directory plus one
  vendored artifact.
- Unlike SecureShellGo, **the tarball this package builds is *not* the
  whole repository.** `scripts/release/build-ppa-source.sh` stages a
  scratch directory containing only `debian/` (with the freshly compiled
  binary added), `LICENSE` and `README.md`, and builds the source package
  from *that* — not from the live working tree. The Dart source, tests and
  fixtures never reach the tarball, because nothing on the builder ever
  compiles them. This is a smaller version of the same trade-off, made
  possible by having nothing left to build.

### A real bug this approach hits, and how `debian/rules` avoids it

Running the source package build and then a full binary build locally
(see "What was actually proven locally" below) surfaced a genuine problem,
not a hypothetical one: **`dh_strip` corrupts a `dart compile exe` binary.**
The build does not fail — it produces a `.deb` that installs and a binary
that still runs — but the installed `winbridge --version` prints the bare
Dart SDK's own version banner ("Dart SDK version: ...") instead of
WinBridge's, because stripping a second time (the binary is already
stripped by `dart compile exe` itself) damages the embedded AOT snapshot.
`debian/rules` skips `dh_strip` entirely (`override_dh_strip` is a no-op),
the same way SecureShellGo's `debian/rules` skips it for its prebuilt
Flutter engine binaries, and for the same category of reason: a toolchain
other than debhelper's already decided what these bytes are, and
debhelper's own idea of "clean up the binary" does not apply to output it
did not produce.

`debian/rules` also deliberately has **no `override_dh_auto_clean`.**
`dpkg-buildpackage -S` runs `debian/rules clean` *before* tarring the
source, and an early version of this rules file cleaned by deleting
`debian/vendor/winbridge` — which deleted the one thing the package exists
to ship, on every single build. Fixed by treating the vendored binary as
source, not as build output that `clean` should remove.

### `scripts/release/build-ppa-source.sh`

Run by hand, never by CI or by any other script in this repository:

```sh
scripts/release/build-ppa-source.sh              # real build: signs, needs the maintainer's GPG key
scripts/release/build-ppa-source.sh --unsigned   # local dry run: debuild -S -us -uc, no key needed
```

It: runs `dart analyze --fatal-infos` (scoped to `lib/` and `bin/` — what
`dart compile exe` actually reaches, not the whole repository, so this
script never blocks a PPA build on a lint issue in, say, another
in-progress feature's test file that never ships in the compiled binary
either way) and `dart test` (the *whole* suite — a release must not skip
that just because part of the repository belongs to someone else's work in
progress); warns, rather than fails, if `debian/changelog`'s version and
`pubspec.yaml`'s disagree, since that is expected while a release is still
being prepared and only has to be true by the time it actually ships;
compiles the binary; stages the scratch source tree described above; runs
`debuild -S`; and **prints the exact `dput` command without ever running
it.** Publishing is the PM's decision, made by hand, every time.

`--skip-checks` also exists, purely for proving the packaging mechanics
(`debian/rules`, `debuild`, `dpkg-source`) in isolation when something
*unrelated* elsewhere in the tree is transiently broken (concurrent,
in-progress work on a different part of the codebase, mid-edit). It must
never be used for an actual release — a release with a failing test suite
is not a release, and the flag says so loudly when it runs.

### The `dput` target

`~/.dput.cf` (read-only) defines it:

```
[dhiva-apps]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~dhiva-labs/ubuntu/apps/
login = anonymous
allow_unsigned_uploads = 0
```

So the command is `dput dhiva-apps <path-to>_source.changes` — `dhiva-apps`
is a host alias name in that config file, not a `ppa:owner/name` Launchpad
reference, matching every `*_source.dhiva-apps.upload` log already in
`~/dhiva-labs/` from this organization's other packages.

### What was actually proven locally

Per the environment this was built in — `debuild`/`debhelper`
13/`devscripts`/`dput` installed, the owner's GPG keys present — PPA source
builds are genuinely executable here, and were actually run, twice over:

1. `scripts/release/build-ppa-source.sh --unsigned --skip-checks` (the
   `--skip-checks` was needed only because unrelated, concurrent
   in-progress work elsewhere in the tree was mid-edit and failing its own
   tests at the time — see the flag's description above) produced a valid
   `.dsc`, `.tar.xz`, `_source.build`, `_source.buildinfo` and
   `_source.changes`. `lintian` ran automatically as part of `debuild` and
   reported one expected error (`source-is-missing`, for the vendored
   binary — the same category of finding a from-source vendored SDK would
   also draw, and the accepted trade-off this whole approach makes) and one
   expected warning (`package-depends-on-hardcoded-libc`, from listing
   `libc6` explicitly in `debian/control` alongside `${shlibs:Depends}` —
   done deliberately, to match the fields specified for this package).
2. A full binary build (`dpkg-buildpackage -us -uc -b`) from the same
   staged source tree produced a working `.deb`: `/usr/bin/winbridge`
   present, executable, and — after the `dh_strip` fix above —
   `winbridge --version` correctly printed `winbridge 0.4.0` rather than
   the corrupted output the first attempt produced. `/usr/share/doc/
   winbridge/copyright` and `changelog.gz` were both present, installed
   automatically by debhelper's own `dh_installdocs`/`dh_installchangelogs`
   from `debian/copyright` and `debian/changelog` — no manual step needed
   for either.

Neither run uploaded anything anywhere.

## Flatpak

`packaging/flatpak/io.github.dhiva_labs.WinBridge.yml` is a manifest, not a
proof: `flatpak-builder` is not installed on this machine, so it has never
actually been built. See `packaging/flatpak/README.md` for the full
picture — what it's supposed to do, how to actually build and validate it
on a machine that has `flatpak-builder`, and what a real Flathub submission
would additionally require (vendoring the Dart SDK rather than a compiled
binary, a no-network build proof, and justifying `--filesystem=host` to a
human reviewer, among others).

The one piece of the Flatpak packaging that *was* checked here:
`packaging/flatpak/metainfo/io.github.dhiva_labs.WinBridge.metainfo.xml`
passes `appstreamcli validate` (installed on this machine even though
`flatpak-builder` is not) cleanly, aside from one pedantic-level note about
the app-id's capitalization — which is the exact app-id this manifest was
specified to use.

## How a version bump flows

1. **`pubspec.yaml`'s `version` field** is the source of truth. Bumped
   alongside `lib/src/core/version.dart`'s `packageVersion` constant, which
   is what `winbridge --version` and every "reports its own version" path
   (including `winbridge report`, see below) actually reads. The two must
   agree — nothing enforces that mechanically beyond code review, since
   `version.dart`'s own doc comment says so and both are outside this
   change's directories.
2. **`git tag vX.Y.Z` and `git push --tags`** (by whoever is doing the
   release; not automated, and this repository's tooling never invents a
   tag on its own). This is what `.github/workflows/release.yml` triggers
   on, and its first real step is checking the tag agrees with
   `pubspec.yaml` — see above.
3. **The GitHub release** (tarball + `.deb` + `SHA256SUMS`) is fully
   automated from that point: the workflow builds and publishes it with no
   further human input.
4. **The PPA** is not automated past that point. Someone runs
   `scripts/release/build-ppa-source.sh` (after bumping `debian/changelog`
   with a new entry for the version — that file is not derived from
   `pubspec.yaml` automatically either), reviews what it built, and runs
   the `dput` command it prints, by hand, when they are ready.
5. **The Flatpak manifest's pinned `url`/`sha256`** need a matching bump —
   currently to whatever the new GitHub release publishes — which is a
   manual edit today (see the comment beside the pin in the manifest
   itself). Automating that bump as part of `release.yml` is a reasonable
   follow-up and is called out as one in `packaging/flatpak/README.md`
   rather than attempted here, since `flatpak-builder` isn't available on
   this machine to verify the result of automating it.

## `winbridge report` and this document

`winbridge report` (see `lib/src/report/`) is not a distribution channel —
it sends nothing anywhere on its own — but it exists for the same reason
this document does: making it easy to tell maintainers what actually works
on a piece of hardware, so `COMPATIBILITY.md` grows from real reports
instead of guesses. See `COMPATIBILITY.md` for the table it feeds and the
process around it.
