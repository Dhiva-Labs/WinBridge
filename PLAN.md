# WinBridge — project plan

**Mission: anything you can do on Windows, you can do from Linux — for
everyone.** Build for it, run its apps, drive its hardware. This is a
community project, not a tool for one machine: nothing may assume a particular
GPU vendor, printer brand, or system layout. Detect what the user actually
has, and have an honest documented answer for every configuration — including
the configurations where the honest answer is a trade-off.

WinBridge is a two-way bridge between Windows and Ubuntu:

1. **Build for Windows from Linux** — a `winbridge` CLI that turns a Linux machine
   into a Windows build machine: native cross-compilation where the language
   allows it, and a headless Windows VM build path where it does not
   (Flutter, MSVC-only projects).
2. **Run Windows apps on Linux** — a launcher that routes a Windows app through
   a Wine/Proton translation path, or through a KVM VM with seamless RemoteApp
   windows for apps Wine cannot handle.

Both directions share the same two engines: a managed Wine runtime and a managed
KVM Windows VM.

## Principles

- **Right tool for each layer — this is not a single-language codebase.** The
  CLI front-end is Dart, but components choose their own implementation:
  shell where it glues, PowerShell on the VM side, and compiled languages
  (Go, Rust, C) for daemons or low-level pieces when a milestone calls for
  them. The discipline that keeps this sane: components talk through
  processes, files, and JSON — never in-process language bindings; every
  component ships with its own tests; CI covers all of them.
- **Zero sudo where possible.** Toolchains bootstrap into the user's home
  directory; nothing writes outside the project and `~/.cache/winbridge`.
- **No shell interpolation, ever.** Every external process is spawned with an
  argv array. User input never passes through a shell.
- **The cheap path first.** Native cross-compilers over Wine, Wine over the VM.
  The VM is the tool of last resort, not the default.
- **Every milestone ships tested and reviewed.** A milestone is done when its
  test gate and security gate below both pass — not before.

## Milestones

### M1 — cross-compile toolbox (current)

The `winbridge` CLI with `build`, `detect`, and `doctor` commands.

- Project detection: Go, Rust, .NET, C/C++, Flutter.
- Toolchain adapters that need no Windows anything:
  - Go → `GOOS=windows GOARCH=amd64`
  - Rust → `x86_64-pc-windows-gnu`
  - .NET → `dotnet publish -r win-x64`
  - C/C++ → `zig cc -target x86_64-windows-gnu` or MinGW-w64
- PE verification: every produced artifact is checked for a valid Windows
  PE32+ header before the build is reported as a success.
- Tool resolution searches `PATH` plus `~/.cache/winbridge/toolchains/*/bin`,
  so bootstrapped toolchains work without sudo or shell profile edits.

**Test gate:** unit tests for detection, resolution, and command construction;
integration tests that produce and verify real `.exe` files with the Go and
Zig toolchains; full language matrix in CI.
**Security gate:** argv-only process execution audited; no shell usage;
fixture and artifact paths validated; `dart analyze` clean.

### M2 — Flutter VM build path (current)

`flutter build windows` requires Windows and Visual Studio. WinBridge drives a
headless KVM Windows VM as a build machine so the developer never leaves Linux.

- VM provisioning scripts and documentation (dockur/windows or virt-install,
  plus a one-time Windows-side setup script for VS Build Tools + Flutter).
- Build driver over OpenSSH: sync sources to the VM, run the build, fetch
  `.exe`/bundle artifacts back into the Linux working tree.
- `winbridge vm status` / `winbridge vm doctor` for connectivity checks.

**Test gate:** transport unit-tested against a fake; artifact-fetch path
handling covered by tests; provisioning scripts lint-clean; end-to-end
documented and verified against a real VM before the milestone closes.
**Security gate:** strict SSH host-key checking by default; key-based auth
only; artifact extraction refuses absolute paths and `..` traversal; VM
treated as semi-trusted (its outputs are data, never executed on the host).

### M2.5 — device bridge (current)

Windows kernel drivers can never load into the Linux kernel, but the VM can
host them and WinBridge can route devices and jobs to it.

- `winbridge vm usb list`: enumerate host USB devices; `winbridge vm usb
  passthrough <vendor:product>`: emit the exact dockur/windows compose and
  libvirt configuration to hand that device to the VM, where its Windows
  driver installs normally.
- Print bridge for Windows-only (GDI) printers: a CUPS-fed path that ships the
  rendered PDF to the VM over the existing SSH transport and prints it there
  through the vendor driver. Driverless IPP is documented as the first resort —
  most modern printers need no driver at all on Linux.
- GPU documentation: why a Windows GPU driver cannot drive a Linux desktop,
  how to install the native driver instead, and VFIO passthrough for giving a
  GPU to the VM.

**Test gate:** lsusb parsing and configuration emission unit-tested against
captured fixtures; print scripts lint-reviewed; walkthroughs verified against
a real VM before the milestone closes.
**Security gate:** device ids validated (strict hex `vvvv:pppp`) before they
reach any emitted configuration; print path reuses the validated SSH
transport; no new remote input reaches a shell unvalidated.

### M3 — MSVC ABI on Linux

- `clang-cl` + `xwin` for MSVC-target C/C++ without Windows (and `cargo-xwin`
  for Rust's MSVC target).
- `msvc-wine` for projects that require the genuine `cl.exe`.
- Installer packaging (`makensis` for NSIS, WiX on .NET for MSI) and
  Authenticode signing via `osslsigncode`.
- `winbridge doctor --install`: no-sudo bootstrap of missing toolchains.

**Gates:** signed sample installer built end-to-end in CI; signing keys never
touch argv or logs; downloads pinned to official origins with checksums.

### M4 — run Windows apps: launcher MVP

- Bundled Wine-GE runtime; one isolated prefix per app; DXVK installed
  automatically; `.desktop` entries so installed apps appear in the launcher;
  uninstall = delete the prefix.

**Gates:** prefix isolation tests; no writes outside prefix and config dirs;
runtime download checksummed.

### M5 — compatibility recipes and VM fallback for running apps

- Recipe database keyed by installer fingerprint (winetricks verbs, DLL
  overrides), community-contributable.
- FreeRDP RemoteApp path against the M2 VM for apps Wine cannot run.

**Gates:** recipes are declarative data, never executable code; RDP
credentials stored with 0600 permissions outside the repo.

### M6 — distribution and community

- Flatpak first (Wine under strict Snap confinement is not viable), then PPA.
- GPU/Vulkan preflight checks; opt-in anonymous success reports feeding
  per-app compatibility scores.
- Community hardware knowledge: the hardware-report issue template feeds a
  published compatibility list (which devices work natively, which need the
  VM, which are poor fits), so nobody has to rediscover what another user
  already learned.

## Testing policy

- `dart analyze` and the full test suite must pass on every commit to `main`.
- Integration tests skip gracefully when a toolchain is absent locally; CI
  runs the full matrix so nothing is skipped there.
- Anything that talks to a network or a VM is behind an interface with a fake
  implementation for tests.

## Security policy

Every milestone closes with a review against, at minimum:

- Command injection: argv-only spawning, no `sh -c` with variable content.
- Path traversal: all paths derived from external input (VM artifacts,
  archives, config) are validated before use.
- Transport security: SSH strict host-key checking, key auth, no passwords in
  code, argv, or logs.
- Secrets hygiene: nothing sensitive in the repo, in defaults, or in error
  messages; config files created 0600.
- Dependency surface: keep third-party packages minimal and pinned.
