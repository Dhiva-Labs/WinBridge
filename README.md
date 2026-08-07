# WinBridge

WinBridge builds Windows binaries from Linux, without leaving Linux.

It detects a project (Go, Rust, .NET, C/C++, Flutter), picks the cheapest
toolchain that can produce a Windows binary for it, and verifies the result
is a real PE32+ executable before calling the build a success. Native
cross-compilers are used wherever the language allows it; Flutter, which
needs Visual Studio and only runs on Windows, is built on a headless VM that
WinBridge drives over SSH — see `docs/vm-setup.md`.

Running Windows apps *on* Linux is the other half of the project and is on
the roadmap; see `PLAN.md`.

## Install

From the [releases page](https://github.com/Dhiva-Labs/WinBridge/releases) —
on Debian/Ubuntu:

```sh
curl -LO https://github.com/Dhiva-Labs/WinBridge/releases/download/v0.1.0/winbridge_0.1.0-1_amd64.deb
sudo apt install ./winbridge_0.1.0-1_amd64.deb
winbridge doctor
```

or on any Linux x86-64, no root needed:

```sh
curl -LO https://github.com/Dhiva-Labs/WinBridge/releases/download/v0.1.0/winbridge-0.1.0-linux-x64.tar.gz
tar -xzf winbridge-0.1.0-linux-x64.tar.gz
install -Dm755 winbridge ~/.local/bin/winbridge
winbridge doctor
```

Verify the download against the release's `SHA256SUMS` asset with
`sha256sum -c`.

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
