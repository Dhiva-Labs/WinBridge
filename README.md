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

## Quick start

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

Run with `--verbose` for every resolved tool path and command line.

## Supported toolchains

| Project | Toolchain | How |
| --- | --- | --- |
| Go (`go.mod`) | `go` | `GOOS=windows GOARCH=amd64 go build` |
| Rust (`Cargo.toml`) | `rust` | `cargo build --target x86_64-pc-windows-gnu` |
| .NET (`*.csproj`/`*.fsproj`) | `dotnet` | `dotnet publish -r win-x64` |
| C/C++ (`CMakeLists.txt`, `Makefile`, sources) | `c` | `zig cc`/`zig c++`, or MinGW-w64 |
| Flutter (`pubspec.yaml` with a flutter dependency) | `vm` | `flutter build windows` on a VM over SSH |

Every produced artifact is checked for a valid Windows PE32+ header before
the build is reported as a success — see `docs/DESIGN.md`.

## Documentation

- `PLAN.md` — milestones and the principles the project holds itself to.
- `docs/DESIGN.md` — the contract between the CLI core and toolchain
  adapters: what a `Toolchain` returns, how tools are resolved, the security
  rules that are enforced by tests rather than by review.
- `docs/vm-setup.md` — bringing up the Flutter build VM end to end: KVM
  prerequisites, provisioning scripts, `~/.config/winbridge/vm.json`, and
  troubleshooting.

## Testing

```sh
dart analyze --fatal-infos
dart test
```

Integration tests that need a real toolchain (Go, Zig, a live build VM, ...)
skip gracefully when that toolchain is not present locally; CI runs the full
matrix.
