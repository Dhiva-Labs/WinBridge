# Installers, signing, and the MSVC ABI

Three things that all involve downloading something large from someone else,
which is why they share one rule: **WinBridge never downloads a big component
as a side effect of a build.** Every one of them is `winbridge doctor --install
<name>`, and `winbridge doctor` lists what each costs before you ask for it.

```
Installable components  (winbridge doctor --install <name>)
  system   go     67 MB          Go toolchain, for cross-compiling Go projects
  system   zig    56 MB          Zig, used as the C/C++ cross-compiler
  absent   nsis   2 MB           NSIS, to build Windows installers
  absent   msvc   3 MB now, then ~1-2 GB of Microsoft headers and libraries
```

`system` means the tool already works here but WinBridge did not install it, so
it cannot vouch for those bytes. `managed` means WinBridge downloaded and
checksum-verified it.

## Building an installer

```sh
winbridge build ./myapp
winbridge package ./myapp --app-version 1.2.3
```

That produces `myapp-1.2.3-setup.exe` beside the artifacts. It installs to
Program Files, adds a Start Menu shortcut and an Add/Remove Programs entry, and
ships an uninstaller.

| Flag | Does |
| --- | --- |
| `--artifacts <dir>` | Where the built files are. Defaults to the build output directory. |
| `-o, --output <file>` | Where to write the installer. |
| `--app-version <x.y.z>` | Version recorded in the installer. Defaults to `0.0.0`. |
| `--script <file.nsi>` | Use your own NSIS script instead of the generated one. |
| `--sign <cert.pfx>` | Authenticode-sign the result. |

Everything in the artifact directory is packaged, minus anything a previous
packaging run left behind — an installer must not ship the last installer.

### How it works, and why that way

WinBridge runs the **official NSIS Windows build under its own managed Wine** —
the same engine `winbridge run` installs. There is a Linux-native NSIS in most
distributions, but using it would mean depending on whatever version a
distribution ships, and on it being installed at all. One pinned NSIS behaves
the same everywhere, and it costs nothing extra because the Wine runtime is
already there for `run`.

The generated script uses **bare file names, never absolute paths**. NSIS uses
`/` to introduce options, so an absolute Unix path handed to `makensis` parses
as a flag — it answers with its usage text and exits non-zero. WinBridge runs
`makensis` from the artifact directory instead, and moves the result if
`--output` points elsewhere.

NSIS builds a **32-bit** installer on purpose, so it runs on any Windows
whatever it installs. WinBridge checks the installer is a valid PE image but
deliberately does not apply the x86-64 rule it applies to build artifacts.

### Your own script

```sh
winbridge package ./myapp --script installer/myapp.nsi -o dist/setup.exe
```

The generated script is written next to the artifacts on every run and
regenerated each time, so the way to take over is to copy it, edit the copy,
and pass `--script`.

## Signing

```sh
export WINBRIDGE_SIGN_PASSPHRASE='...'      # or leave unset to be prompted
winbridge package ./myapp --sign certs/app.pfx
```

**The passphrase never appears in an argument vector.** Anything on argv is
readable by every process on the machine through `/proc/<pid>/cmdline`, and
ends up in shell history and CI logs besides. WinBridge offers no flag that
would carry one: the passphrase comes from `WINBRIDGE_SIGN_PASSPHRASE` or from
osslsigncode's own prompt, and when it comes from the environment it is written
to a `0700` temporary file for `-readpass` and deleted in a `finally` block. A
test asserts the constructed command contains no passphrase option, so a future
change that adds one fails the suite.

Signatures are timestamped (RFC 3161) by default so they outlive the
certificate.

`osslsigncode` is **not** downloaded — it is a small distribution package
(`apt install osslsigncode`), and bootstrapping a signing tool silently is not
something to do quietly. If it is absent, `--sign` fails with that message
rather than shipping an unsigned installer.

## The MSVC ABI

WinBridge's default C/C++ path is `zig cc` targeting the MinGW ABI: no licence,
no multi-gigabyte SDK, works out of the box. Use `--toolchain msvc` when you
genuinely need Microsoft's ABI — linking a vendor library built with MSVC, or
code using MSVC-specific extensions.

```sh
winbridge doctor --install msvc      # xwin, then the CRT and Windows SDK
winbridge build ./myapp --toolchain msvc
```

`doctor --install msvc` downloads [xwin](https://github.com/Jake-Shadle/xwin)
(3 MB, pinned and checksum-verified), then uses it to fetch Microsoft's CRT and
Windows SDK into `~/.cache/winbridge/xwin` — 1-2 GB, from Microsoft's servers,
under **Microsoft's licence**. That step passes `--accept-license` to xwin on
your behalf, which is you accepting those terms; the command prints them first.
Those gigabytes are not pinned by WinBridge because they are not WinBridge's to
pin: they come from Microsoft at the version xwin resolves.

A build without the SDK fails with the command that fixes it and downloads
nothing.

### lld-link is not downloaded, and that is deliberate

Linking the MSVC ABI needs `lld-link`. WinBridge resolves it from the search
path, including the versioned spellings distributions actually use
(`lld-link-18`, `ld.lld`, `lld`), and passes the one it found to clang with
`--ld-path` rather than hoping the right name is on `PATH`.

If it is missing, WinBridge says so and stops. It does **not** download it: the
only official distribution of `lld-link` is a ~1.5 GB LLVM toolchain archive,
and pulling that down to extract one binary is a bad trade when `apt install
lld` is about 30 MB. Honest failure beat coverage here.

### What is verified, and what is not

The MSVC path is **not verified end to end** in this repository. The machine it
was built on has clang (and `clang --driver-mode=cl` does produce COFF objects)
but no `lld-link` and no Windows SDK, and neither is something to download in a
test run.

What *is* verified: the exact argument vector — driver mode, target triple,
`--ld-path`, `/imsvc` system includes, `/libpath:` ordering after `/link`,
object output redirected to the cache, release versus debug, C++ exception
handling — plus that a build without the SDK fails with actionable text and
spawns no process at all. What is not verified is that those arguments compile
and link a real program against a real Windows SDK. Treat the MSVC adapter as
untested-in-anger until someone runs it with the splat in place.

## MSI and WiX: not shipped

WiX would need a .NET SDK, and `dotnet` is not installed here. It could be
bootstrapped as a pinned asset — Microsoft publishes official SDK tarballs that
install without root — but that would mean shipping a code path nobody has
executed once, on top of a WiX toolchain nobody has run. That is exactly the
kind of feature that looks finished in a changelog and fails on first contact.

So: MSI is future work. What it needs, concretely — pin the .NET SDK tarball as
a `PinnedAsset` alongside the others, add a `wix` component to `doctor
--install`, and generate a `.wxs` the way NSIS scripts are generated now. The
`AssetCache` and installer plumbing it would sit on already exist.

NSIS covers the common case: a single-executable app that needs to land in
Program Files with a shortcut and an uninstaller.

## Notes for CI

- **NSIS** works in CI today with no extra setup beyond a cached Wine runtime;
  `winbridge package` is exercised end to end by
  `test/package/package_integration_test.dart`, which skips cleanly when no
  runtime is present.
- **osslsigncode** is an `apt-get install osslsigncode` away, so a CI job can
  real-test signing against a self-signed `.pfx`. Only command construction is
  unit-tested here.
- **The MSVC splat** is 1-2 GB, so caching `~/.cache/winbridge/xwin` between
  runs is the only sane way to test it. It also needs `lld` installed. Worth
  doing as a separate, non-blocking job rather than on every push.
