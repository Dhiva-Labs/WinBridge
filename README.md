# WinBridge

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

From the [releases page](https://github.com/Dhiva-Labs/WinBridge/releases) —
on Debian/Ubuntu:

```sh
curl -LO https://github.com/Dhiva-Labs/WinBridge/releases/download/v0.4.0/winbridge_0.4.0-1_amd64.deb
sudo apt install ./winbridge_0.4.0-1_amd64.deb
winbridge doctor
```

or on any Linux x86-64, no root needed:

```sh
curl -LO https://github.com/Dhiva-Labs/WinBridge/releases/download/v0.4.0/winbridge-0.4.0-linux-x64.tar.gz
tar -xzf winbridge-0.4.0-linux-x64.tar.gz
install -Dm755 winbridge ~/.local/bin/winbridge
winbridge doctor
```

Verify the download against the release's `SHA256SUMS` asset with
`sha256sum -c`.

Every install channel — this tarball and `.deb`, the `dhiva-apps` PPA, and
Flatpak — is covered in full, including how each one is built and its
current status, in `docs/distribution.md`.

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
matrix.

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
