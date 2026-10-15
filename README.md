# WinBridge

[![ARM64 builds](https://github.com/Dhiva-Labs/WinBridge/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Dhiva-Labs/WinBridge/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Dhiva-Labs/WinBridge)](https://github.com/Dhiva-Labs/WinBridge/releases/latest)
![Linux x64 | arm64](https://img.shields.io/badge/Linux-x64%20%7C%20arm64-informational?logo=linux&logoColor=white)

WinBridge builds Windows binaries from Linux, without leaving Linux.

It detects a project (Go, Rust, .NET, C/C++, Flutter), picks the cheapest
toolchain that can produce a Windows binary for it, and verifies the result
is a real PE32+ executable before calling the build a success. Native
cross-compilers are used wherever the language allows it; Flutter, which
needs Visual Studio and only runs on Windows, is built on a headless VM that
WinBridge drives over SSH — see `docs/vm-setup.md`.

It also *runs* them. `winbridge run app.exe` launches a Windows program on
Linux through a Wine runtime WinBridge downloads and manages itself — nothing
to install, nothing to configure. See `docs/running.md`.

## Install

From the [releases page](https://github.com/Dhiva-Labs/WinBridge/releases).
Each release carries a tarball and a `.deb` for **x64 (amd64)** and for
**arm64 (aarch64)** — pick the one that matches `uname -m` (`x86_64` or
`aarch64`) — and a `SHA256SUMS` covering all of them. Releases up to v0.4.0 are
x64 only; arm64 files are published from v0.5.0 on.

On Debian/Ubuntu:

```sh
VERSION=0.5.0
ARCH="$(dpkg --print-architecture)"   # amd64 or arm64
curl -LO "https://github.com/Dhiva-Labs/WinBridge/releases/download/v${VERSION}/winbridge_${VERSION}-1_${ARCH}.deb"
sudo apt install "./winbridge_${VERSION}-1_${ARCH}.deb"
winbridge doctor
```

or on any Linux x86-64 or arm64, no root needed:

```sh
VERSION=0.5.0
ARCH="$(case "$(uname -m)" in x86_64) echo x64 ;; aarch64) echo arm64 ;; esac)"
curl -LO "https://github.com/Dhiva-Labs/WinBridge/releases/download/v${VERSION}/winbridge-${VERSION}-linux-${ARCH}.tar.gz"
tar -xzf "winbridge-${VERSION}-linux-${ARCH}.tar.gz"
install -Dm755 "winbridge-${VERSION}-linux-${ARCH}/winbridge" ~/.local/bin/winbridge
winbridge doctor
```

Verify the download against the release's `SHA256SUMS` asset with
`sha256sum -c --ignore-missing SHA256SUMS`.

Every install channel — this tarball and `.deb`, the `dhiva-apps` PPA, and
Flatpak — is covered in full, including how each one is built and its
current status, in `docs/distribution.md`.

## ARM64 hosts

WinBridge itself runs natively on Linux arm64. Its CI builds, tests and
packages it on real arm64 machines (no emulation) next to x64, so the
`winbridge-<version>-linux-arm64.tar.gz` and `winbridge_<version>-1_arm64.deb`
release files are the same program, compiled for that CPU.

**What works on an arm64 host**

- `winbridge build` for Go, Rust (`x86_64-pc-windows-gnu`), .NET (`win-x64`)
  and C/C++ (`zig cc`, or MinGW-w64). It produces the same Windows x86-64
  binaries an x64 host does, and every one is still checked for a real PE32+
  header. The host CPU only decides which compiler runs.
- `winbridge doctor --install go|zig|msvc` downloads the **arm64** build of
  Go, Zig or xwin, verified against a pinned SHA-256, never the x64 one.
  (Rust and .NET come from your own install, as on x64; on Debian/Ubuntu arm64
  the MinGW linker Rust needs is the `gcc-mingw-w64-x86-64` package.)
- `detect`, `doctor`, `report`, `recipe list|show` and the Flutter
  build VM commands (`winbridge vm ...`), which drive a Windows VM over SSH and
  do not care what CPU the host has.

**What does not work on an arm64 host**

- `winbridge run`, `winbridge prefix tricks`, `--dxvk`, `winbridge package`
  (it runs NSIS under Wine) and `winbridge recipe apply` for a recipe that has
  something to apply. They all need Wine, and the Wine WinBridge manages is an
  x86-64 build. No arm64 Wine that runs x86-64 Windows programs is available
  in a form WinBridge can pin by checksum and unpack without root, so on arm64
  these commands stop immediately with an explanation. They download nothing
  and create no prefix, and `winbridge doctor` reports the same thing.
- A `wine` found on `PATH` is not used automatically on arm64: a Wine built
  natively for arm64 cannot run the x86-64 programs WinBridge builds. If you
  have one that does (a Hangover build, for example), set
  `WINBRIDGE_WINE=/path/to/wine` and WinBridge uses it as given. That route is
  yours to verify; WinBridge does not test it.
- The bundled `scripts/vm/docker-compose.yml` (a local Windows VM under KVM) is
  written for x86-64 hosts and has not been tried on arm64. Point
  `~/.config/winbridge/vm.json` at any Windows VM you can reach over SSH.

## Quick start from source

```sh
dart pub get
dart run bin/winbridge.dart doctor
dart run bin/winbridge.dart build path/to/project
```

For a standalone binary:

```sh
dart compile exe bin/winbridge.dart -o winbridge
./winbridge build path/to/project
```

## Commands

- `winbridge build [directory] [-- extra tool arguments]` — build a project
  for Windows. `--target windows-x64|windows-arm64`, `--debug`, `--output
  <dir>`. Anything after `--` is passed straight through to the underlying
  compiler.
- `winbridge run <app.exe> [-- arguments for the app]` — run a Windows program
  on Linux. `--prefix <name>` picks which app world to use, `--list-prefixes`
  shows what exists. See `docs/running.md`.
- `winbridge detect [directory]` — report what project type WinBridge sees
  and which toolchain would build it, without building anything.
- `winbridge doctor` — check which toolchains have their required tools
  available on this machine.
- `winbridge vm status` / `winbridge vm doctor` — connectivity and setup
  checks for the Flutter build VM. See `docs/vm-setup.md`.
- `winbridge vm usb list` / `winbridge vm usb passthrough <vendor:product>` —
  see hardware attached to this host and print the VM configuration to hand
  one device to it. See `docs/devices.md`.

Run with `--verbose` for every resolved tool path and command line.

## Supported toolchains

| Project | Toolchain | How |
| --- | --- | --- |
| Go (`go.mod`) | `go` | `GOOS=windows GOARCH=amd64 go build` |
| Rust (`Cargo.toml`) | `rust` | `cargo build --target x86_64-pc-windows-gnu` |
| .NET (`*.csproj`/`*.fsproj`) | `dotnet` | `dotnet publish -r win-x64` |
| C/C++ (`CMakeLists.txt`, `Makefile`, sources) | `c` | `zig cc`/`zig c++`, or MinGW-w64 |
| Flutter (`pubspec.yaml` with a flutter dependency) | `vm` | `flutter build windows` on a VM over SSH |

C/C++ is the one partial row. WinBridge *detects* a project from
`CMakeLists.txt` or a `Makefile`, but the M1 adapter compiles top-level and
`src/` sources directly — it does not drive CMake or Make. A project that only
builds through one of those is reported as unsupported rather than silently
mishandled; driving real build systems is future work.

Every produced artifact is checked for a valid Windows PE32+ header before
the build is reported as a success — see `docs/DESIGN.md`.

## Running what you built

```sh
winbridge build ./myapp
winbridge run myapp/build/winbridge/windows-x64/myapp.exe
```

The first `run` downloads the pinned Wine build into
`~/.cache/winbridge/runtimes/` and checks it against an embedded SHA-256. Each
app gets its own prefix under `~/.local/share/winbridge/prefixes/`, so
resetting an app is deleting one directory. Console output streams through and
the app's exit code becomes `winbridge run`'s.

Direct3D apps can render through Vulkan with `winbridge run --dxvk` (sticky
per app), and `winbridge prefix tricks <app> <verb...>` installs extra
runtimes an app needs (fonts, VC++ redistributables) into just that app's
prefix. See `docs/running.md` for what works today and what does not.

## Desktop entries

Make an app WinBridge runs show up in your desktop launcher, instead of only
under `winbridge run`:

```sh
winbridge desktop add myapp/build/winbridge/windows-x64/myapp.exe
winbridge desktop add path/to/game.exe --name "My Game" --prefix game
winbridge desktop list
winbridge desktop remove myapp
```

`add` writes `~/.local/share/applications/winbridge-<name>.desktop` (honouring
`XDG_DATA_HOME`), pointed at `winbridge run --prefix <prefix> <exe>`. `list`
shows only the entries WinBridge itself created; `remove` deletes one by name
and refuses to touch anything it did not write.

The entry's `Exec=` line calls plain `winbridge`, so it only works if
`winbridge` is on `PATH` — true for the `.deb` install, and true once you have
`~/.local/bin` (or wherever you installed it) on `PATH` for the tarball
install.

Icons are generic (`application-x-executable`) for now — extracting an app's
own icon out of its `.exe` is future work.

## Windows-only devices

Printers, USB gadgets and GPUs that need Windows-only software — a vendor's
maintenance utility, a GDI-only print driver, a companion app — route through
the same build VM: `winbridge vm usb passthrough` hands a device to it, and
`scripts/printing/` bridges print jobs to a Windows driver over SSH. Most
hardware has a native Linux path that needs none of this; see
`docs/devices.md` for the decision path and worked examples before reaching
for the VM.

## Documentation

- `PLAN.md` — milestones and the principles the project holds itself to.
- `docs/DESIGN.md` — the contract between the CLI core and toolchain
  adapters: what a `Toolchain` returns, how tools are resolved, the security
  rules that are enforced by tests rather than by review.
- `docs/vm-setup.md` — bringing up the Flutter build VM end to end: KVM
  prerequisites, provisioning scripts, `~/.config/winbridge/vm.json`, and
  troubleshooting.
- `docs/devices.md` — routing printers, USB devices and GPUs through the
  build VM for the Windows-only pieces they need, and the native Linux path
  to check first.

## Testing

```sh
dart analyze --fatal-infos
dart test
```

Integration tests that need a real toolchain (Go, Zig, a live build VM, ...)
skip gracefully when that toolchain is not present locally; CI runs the full
matrix, on an x64 and an arm64 machine. The architecture-dependent behaviour
(which download is chosen, whether Wine is on offer) takes the host CPU as an
input, so the arm64 paths are also tested on x64 and the other way round.

## Reporting hardware and compatibility

```sh
winbridge report
```

Prints a filled-in copy of the hardware-report issue template — OS/kernel,
CPU, GPU, Vulkan, WinBridge's own Wine runtime and prefix/DXVK state, and
which toolchains are ready to build with — gathered strictly from this
machine. Nothing it gathers is sent anywhere by the command itself; it
prints the report and the URL to paste it into if you choose to share it.
No hostname, no username, and no path under your home directory reaches the
output — see `lib/src/report/` if you want to verify that yourself.

See `COMPATIBILITY.md` for what this repository has actually verified so
far and how a hardware report becomes a row in that table.
