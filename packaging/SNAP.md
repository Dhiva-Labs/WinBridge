# Publishing WinBridge to the Snap Store

Snap name: `winbridge`. Source of truth: `snap/snapcraft.yaml`.

## Status

**Built and tested locally (0.4.0, core22, classic); not yet registered,
uploaded or released.**
Publishing needs three things, in this order, and the order matters (see
"The sequencing trap" below):

1. `snapcraft register winbridge` (once).
2. A classic-confinement request on the Snap Store forum, **approved**
   (draft below). Classic is never granted automatically.
3. `snapcraft upload --release=stable winbridge_0.4.0_amd64.snap`.

## Confinement: classic, and why

`confinement: classic`, `base: core22`. This was evaluated, not assumed;
strict was ruled out because WinBridge's core function is to run programs
that live outside any snap:

| What WinBridge does | Strict-confinement answer | Verdict |
| --- | --- | --- |
| `winbridge build` runs the user's own `go`, `cargo`/`rustup`, `dotnet`, `zig`, MinGW (`x86_64-w64-mingw32-gcc`), `clang`/`lld-link`, `flutter` from `PATH`, `/usr/local/go`, `~/.cargo`, `~/.rustup`, `~/.dotnet` and `~/.cache/winbridge/toolchains` | No interface lets a confined process execute arbitrary host executables with their host libraries and host configuration. Bundling copies of every compiler would defeat the point (the user's pinned versions, installed targets and module caches are the build) and is not feasible for .NET/Rust/Go/Zig/MinGW together. | Insufficient |
| Build inputs and outputs are arbitrary directories given on the command line (`winbridge build /mnt/work/app`, `winbridge run /opt/game/game.exe`) | `home` exposes only non-hidden paths under `$HOME`; `removable-media` needs a manual connect and only covers `/media`, `/run/media`, `/mnt`. Nothing covers `/opt`, `/srv`, `/data`, `/tmp` work trees, or hidden directories such as `~/.cargo`. | Insufficient |
| State lives in `~/.cache/winbridge` (managed toolchains, pinned Wine, DXVK) and `~/.local/share/winbridge` (per-app prefixes, user recipes) | Hidden directories under `$HOME`; only reachable through `personal-files` (itself a store-reviewed, non-auto-connected request) and the toolchains it holds would still need to be executable from host paths. | Insufficient |
| `winbridge run` launches Windows programs through a downloaded Wine, with optional DXVK (Vulkan) and winetricks | Needs the host display, audio, GPU/Vulkan ICDs and input devices, and executes downloaded runtimes plus arbitrary user-supplied Windows binaries that each want their own host integration. | Insufficient |
| `winbridge desktop add` writes `~/.local/share/applications/winbridge-*.desktop` and runs `update-desktop-database` | Hidden path outside `home`; `personal-files` again. | Insufficient |
| Flutter builds are driven on a KVM Windows VM through `ssh`/`rsync` (`winbridge vm ...`) using the user's `~/.ssh` keys and ssh-agent | `ssh-keys` is manual-connect and reads only `~/.ssh`; the agent socket is not reachable from a strict snap; the confined app could not run the host `ssh`/`rsync` anyway. | Insufficient |
| `winbridge vm usb list` runs `lsusb`; printing/USB bridges print libvirt/QEMU/docker configuration for the VM | Needs the host `lsusb` and `lspci`/`vulkaninfo`. | Insufficient |

The same reasoning is why IDEs, compilers and build systems (`code`, the
JetBrains IDEs, `go`, `rustup`, `zig`, `cmake`) are classic snaps.

What the snap itself contains: the `dart compile exe` AOT binary at
`$SNAP/bin/winbridge` (built inside the core22 container), the bundled
recipes, the VM setup/printing scripts, and the docs. It deliberately bundles **no**
toolchains. Everything WinBridge shells out to (`curl`, `tar`/`xz-utils`,
`unzip`, `sha256sum`, and optionally `ssh`/`rsync`) comes from the host;
`winbridge doctor` says what is missing.

### Forum request (draft, ready to post)

Post at <https://forum.snapcraft.io/c/store-requests/classic-confinement/26>
after `snapcraft register winbridge` has succeeded.

> **Title:** Classic confinement request: winbridge
>
> **Name:** winbridge
> **Snap Store:** https://snapcraft.io/winbridge
> **Source:** https://github.com/Dhiva-Labs/WinBridge (MIT)
> **Publisher/upstream:** I (Dhiva Labs) am the upstream author and the
> publisher of this snap.
> **Category:** developer tool — a build tool / cross-compiler driver, the
> same class as the compiler and IDE snaps that are granted classic.
>
> **What it does.** WinBridge is a command-line tool that builds Windows
> executables from Linux. It detects a project (Go, Rust, .NET, C/C++,
> Flutter), picks the cheapest cross-compile route, invokes the toolchains
> the developer already has installed on the host (`go`, `cargo`/`rustup`
> with the `windows-gnu` target, `dotnet`, `zig cc`, MinGW, `clang`/`lld-link`,
> and `ssh`/`rsync` to a Windows build VM for Flutter), and verifies the
> result is a real PE32+ binary. It can also run Windows programs through a
> pinned Wine that it downloads and checksum-verifies into `~/.cache/winbridge`.
>
> **Why strict confinement does not work.**
>
> 1. *It must execute host toolchains.* The product is orchestrating the
>    user's own compilers (`go`, `cargo`, `dotnet`, `zig`, MinGW, `clang`,
>    `flutter`, `ssh`). No interface allows a confined snap to run arbitrary
>    host executables with the host's libraries, module caches and config.
>    Bundling them is not viable: the user's installed targets, pinned
>    versions and caches are what must be used.
> 2. *It reads and writes arbitrary directories.* Project and output
>    directories are command-line arguments and live anywhere (`/mnt`,
>    `/opt`, `/srv`, other drives, hidden directories such as `~/.cargo`
>    and `~/.rustup`). `home` covers only non-hidden `$HOME` paths and
>    `removable-media` only `/media`, `/run/media` and `/mnt`.
> 3. *It manages toolchains and per-app Wine prefixes in hidden host
>    directories* (`~/.cache/winbridge`, `~/.local/share/winbridge`) and
>    writes desktop launchers to `~/.local/share/applications`.
>    `personal-files` could cover these paths, but it does not solve (1).
> 4. *It runs a downloaded Wine/DXVK and arbitrary Windows binaries,* which
>    need the host display, audio, GPU and Vulkan stack.
> 5. *The Flutter build path drives a Windows VM over the user's ssh* with
>    their keys and agent, which `ssh-keys` cannot provide (no agent socket,
>    no host `ssh`/`rsync` binaries).
>
> **Interfaces considered:** `home`, `removable-media`, `personal-files`,
> `system-files`, `ssh-keys`, `network`, `network-bind`, `hardware-observe`,
> `raw-usb`, `x11`, `wayland`, `opengl`, `audio-playback`. None of them
> lets a snap run the host's compilers, which is the central requirement;
> the rest only widen file access piecemeal.
>
> **Precedent:** compiler/toolchain and IDE snaps with the same need
> (running host toolchains and touching any project path) are already
> classic.
>
> The snap bundles only the WinBridge binary (a Dart AOT executable built
> inside the core22 build container), bundled recipes and documentation. It
> bundles no libraries or toolchains and sets no `LD_LIBRARY_PATH`, so the
> host tools it launches run unmodified; I tested it on Ubuntu 24.04 by
> cross-compiling Go and C projects to PE32+ and running a Windows program
> under its managed Wine. `snap/snapcraft.yaml` and `packaging/SNAP.md` are
> in the repository. Thanks for reviewing.

## The sequencing trap (do not skip)

A classic snap that has not been granted classic is **not rejected, it goes
into the manual-review queue**, and a revision sitting in review blocks every
later release of that snap name (BranchPilot and DiscWriter both hit this;
clearing it needs a manual "Reject and remove from review queue" click on
the dashboard). So:

* Register the name, post the request, **wait for the grant**, only then
  upload.
* After the grant, `snapcraft upload --release=stable ...` releases
  automatically if nothing else needs review. Check with
  `snapcraft status winbridge`.

## Building

```bash
snapcraft pack --use-lxd
```

Produces `winbridge_0.4.0_amd64.snap` in the repository root. It is
git-ignored (`*.snap`); never commit it.

What the build does (`snap/snapcraft.yaml`, part `winbridge`):

* Downloads the **pinned Dart SDK 3.12.2** (SHA-256 verified), runs
  `dart pub get --enforce-lockfile` and `dart compile exe bin/winbridge.dart`
  inside the core22 container (Ubuntu 22.04, glibc 2.35), not on the
  developer's machine. `objdump -T` on the result shows it needs only
  `GLIBC_2.18` or older (the Dart AOT runtime is built against an old
  sysroot), so it runs on any current distribution.
* Fails the build if the compiled binary's `--version` disagrees with the
  snap `version`.
* Installs `bin/winbridge`, `share/winbridge/{recipes,vm,printing}` and
  `share/doc/winbridge`. The app sets `WINBRIDGE_RECIPES_DIR` to the bundled
  recipes (`lib/src/recipes/recipe_loader.dart`); the debian package does
  not ship them, the snap does.
* `build-attributes: [no-patchelf]` and no stripping. A `dart compile exe`
  binary carries its AOT snapshot as data appended to the ELF; rewriting
  the ELF corrupts it (the same reason `debian/rules` makes `dh_strip` a
  no-op). This was verified, not assumed: the binary patched the way
  snapcraft's classic linter asks (`patchelf --set-interpreter
  /snap/core22/current/lib64/ld-linux-x86-64.so.2 --set-rpath ...`) still
  starts, but `--version` prints the bare Dart CLI's `Dart SDK version: ...`
  instead of `winbridge 0.4.0`. The binary therefore runs on the host's own
  dynamic linker and libc.
* `lint: ignore: classic: [bin/winbridge]`. Because of the point above,
  snapcraft's classic linter would otherwise warn that the ELF interpreter
  and rpath should point at core22; the ignore is deliberate and commented
  in `snap/snapcraft.yaml`. The reviewer of the classic request may ask
  about it; the answer is the patchelf result above.

The pinned Dart version lives in `override-build`
(`DART_VERSION`/`DART_SHA256`). To bump it, take the checksum from
`https://storage.googleapis.com/dart-archive/channels/stable/release/<ver>/sdk/dartsdk-linux-x64-release.zip.sha256sum`.

For every release: bump `version:` in `snap/snapcraft.yaml` together with
`pubspec.yaml` and `lib/src/core/version.dart` (the build fails if the binary
and the snap disagree), build, test, upload.

## Testing a build

```bash
sudo snap install --dangerous --classic ./winbridge_0.4.0_amd64.snap
winbridge --version
winbridge doctor
```

Results for the 0.4.0 build, on an Ubuntu 24.04 LXD VM with snapd, as the
unprivileged `ubuntu` user (host tools `curl`, `xz`, `tar`, `ssh`, `rsync`,
`go` 1.22 from apt):

| Command | Result |
| --- | --- |
| `winbridge --version` | `winbridge 0.4.0` |
| `winbridge --help`, `winbridge doctor` | work; `doctor` exits 1 when required toolchains are missing, which is its normal behaviour. PATH inside the snap is the host PATH; `LD_LIBRARY_PATH` is not set, so host tools are unaffected. |
| `winbridge recipe list` | finds the bundled recipes at `$SNAP/share/winbridge/recipes` through `WINBRIDGE_RECIPES_DIR` |
| `winbridge build` on a Go hello-world (host `go`) | `hello.exe`, `PE32+ executable (console) x86-64, for MS Windows` |
| same, project under `/srv` (outside `$HOME`) | builds and verifies |
| `winbridge doctor --install zig`, then `winbridge build` on a CMake C project | zig (56 MB) downloaded, checksum-verified and unpacked into `~/.cache/winbridge/toolchains`; `chello.exe` is PE32+ |
| `winbridge run hello.exe` | pinned Wine 11.14 (94 MB) downloaded, prefix created under `~/.local/share/winbridge/prefixes`, output `hello from windows` |
| `winbridge desktop add` / `list` / `remove` | `.desktop` written to `~/.local/share/applications` with `Exec=winbridge run ...`, which resolves through `/snap/bin` |
| `winbridge vm doctor`, `winbridge report` | work (VM correctly reported as unconfigured) |

Not tested: Rust, .NET and the MSVC ABI paths (no toolchains installed in the
VM; they use the same process-spawning code as Go and C), DXVK on real
hardware, the Flutter VM path (needs a Windows VM), and non-Ubuntu hosts.

## Known limitations

* Host tools are the host's: the snap does not install `curl`, `xz-utils`,
  `unzip`, `ssh` or `rsync` for you (the `.deb` pulls them in as Recommends;
  a snap cannot). A download that needs one of them fails with
  ``could not find `curl` (downloads ...)``, naming the tool. Ubuntu desktop
  does not always ship `curl`.
* The classic linter warning is suppressed on purpose (see Building).
* x86-64 only, like the release tarball and `.deb`.
* Classic snaps cannot be installed from the store without `--classic`
  (`sudo snap install winbridge --classic`); that is standard for classic.
