# WinBridge Flatpak packaging

`io.github.dhiva_labs.WinBridge.yml` builds a Flatpak of the `winbridge`
CLI from a pinned GitHub release asset — it downloads and verifies
`winbridge-0.3.0-linux-x64.tar.gz` by SHA-256, installs the binary to
`/app/bin/winbridge`, and does not compile anything.

## Honest status: untested on this machine

**`flatpak-builder` is not installed here, and this manifest has never
actually been built.** Everything above the line is what the manifest is
*supposed* to do, reasoned from the Flatpak/AppStream documentation and
from how the rest of WinBridge's release assets are shaped — it has not
been run. Before this is trusted for anything beyond review:

- Build it on a machine that has `flatpak-builder` and the
  `org.freedesktop.Platform`/`org.freedesktop.Sdk` runtimes (see below), or
- Add a CI job that does the same (this repo's `ci.yml` and `release.yml`
  are outside this M6 slice's directories — wiring one in is a follow-up,
  not done here).

The one piece of this manifest that *was* checked on this machine:
`packaging/flatpak/metainfo/io.github.dhiva_labs.WinBridge.metainfo.xml`
passes `appstreamcli validate` (`appstreamcli` is installed here even
though `flatpak-builder` is not) — clean except one pedantic-level note
that the app-id contains uppercase letters, which is the exact app-id this
manifest was specified to use.

## Building locally

On a machine with `flatpak` and `flatpak-builder`:

```sh
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08

cd packaging/flatpak
flatpak-builder --force-clean build-dir io.github.dhiva_labs.WinBridge.yml

# Run it straight from the build directory without installing:
flatpak-builder --run build-dir io.github.dhiva_labs.WinBridge.yml winbridge --version

# Or install it into the user's own Flatpak installation and run it as a
# normal app would be run:
flatpak-builder --user --install --force-clean build-dir io.github.dhiva_labs.WinBridge.yml
flatpak run io.github.dhiva_labs.WinBridge --version
```

If `runtime-version` in the manifest is older than what `flatpak install`
above pulls, either bump the manifest to match or install the specific
older runtime version the manifest names — they must match exactly.

## What Flathub submission would additionally require

This manifest is shaped for "build and run it yourself" today, not for
Flathub, which has stricter rules this does not yet meet:

- **Vendored binary, not vendored source.** Flathub (and Debian's own
  Free Software Guidelines, for what it's worth even though this isn't a
  Debian package) expect a build to compile from source inside the
  sandbox, not download a pre-built binary — the same gap
  `docs/distribution.md` documents for the PPA package, which vendors a
  `dart compile exe` binary for the same underlying reason: Flathub's
  build infrastructure (like Launchpad's) has no network access during
  the actual build, and the Dart SDK is not among the runtimes it
  provides out of the box. Passing Flathub review would mean either
  vendoring the Dart SDK itself (the same shape of workaround
  SecureShellGo uses for its Flutter SDK — see
  `~/dhiva-labs/secureshellgo_1.4.3~noble1.tar.xz`'s `debian/rules` for
  the pattern, though that is Launchpad's PPA infrastructure, not
  Flathub's, and the two are not guaranteed to accept the same
  workaround) or building Dart's own build tool (`dartaotruntime` plus the
  relevant SDK pieces) as a proper source module from a pinned upstream
  tag — a real project of its own, not attempted here.
- **No-network builds, strictly.** Flathub builders have no network
  access at all during a build, not even to fetch a pinned, checksummed
  archive — every `source:` entry must resolve from what
  `flatpak-builder` downloads and caches *before* the sandboxed build
  starts (which is how the `archive`/`file` sources in this manifest
  already work) or from another vendored module; nothing may reach out
  once the build itself begins. This manifest already only downloads
  during the pre-build fetch step, which is the right shape — the gap is
  the vendored-binary point above, not the network model.
- **`--filesystem=host`.** Flathub review scrutinizes this permission
  heavily and will ask for a narrower one or a documented justification
  for why a picker-based portal isn't an option. The comment beside it in
  the manifest is that justification as it stands today; a real
  submission would need to make the case to a human reviewer, or find a
  narrower alternative (e.g. restricting to `--filesystem=home` and
  documenting that pointing WinBridge at a project outside `$HOME` needs
  a manual override).
- **Runtime version currency.** `runtime-version: '24.08'` needs to be
  whatever the current stable `org.freedesktop.Platform` release is at
  submission time, not whatever was current when this manifest was
  written.
- **An icon.** Console-application components don't strictly require
  one, but Flathub's own listing conventions generally expect one for
  every app regardless of AppStream's minimum. None is provided here.

## Keeping the pinned release current

`io.github.dhiva_labs.WinBridge.yml`'s `url`/`sha256` point at the
`v0.3.0` GitHub release asset, with a comment at the pin explaining why:
it's the newest release published as of this manifest, and bumping it on
every release is intended to be a release-automation follow-up (driven by
`.github/workflows/release.yml`, which is what publishes that asset in
the first place) rather than a hand-edit someone has to remember. See
`docs/distribution.md` for how a version bump is meant to flow end to
end; wiring an automated bump for this file specifically is not done as
part of this change.
