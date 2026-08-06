# Setting up the Flutter build VM

`flutter build windows` only runs on Windows, with Visual Studio's C++ tools
installed. WinBridge's `vm` toolchain gets you a real Windows build without
leaving Linux by driving a headless Windows VM over SSH: your project is
synced across, built there, and the result is fetched back.

This is a one-time setup per VM. Once it is done, `winbridge build` on a
Flutter project just works.

## Prerequisites

- **KVM.** Check with `ls -l /dev/kvm` — it should exist and be usable by
  your user (usually via membership in the `kvm` group: `groups | grep kvm`).
  Without KVM the VM will still boot but will be too slow to be useful for a
  Visual Studio build.
- **Docker and Docker Compose**, for the [dockur/windows](
  https://github.com/dockur/windows) route below. If you would rather not run
  Docker, `virt-install`/`virt-manager` works too — install Windows normally
  from an ISO and then pick up this guide again at
  [Running `setup-windows.ps1`](#running-setup-windowsps1); everything past
  that point only cares that you have *a* Windows VM reachable over SSH, not
  how it was created.
- **~25 GB free disk** for the Windows install, plus room for Visual Studio
  Build Tools and the Flutter SDK inside the guest (another ~15 GB).
- `ssh` and `rsync` on the Linux host. `winbridge vm doctor` checks for both.

## Bringing up the VM

From the repository root:

```sh
cd scripts/vm
docker compose up -d
```

Read `scripts/vm/docker-compose.yml` before you do — change the `PASSWORD`
environment variable, and adjust `RAM_SIZE`/`CPU_CORES`/`DISK_SIZE` to what
your machine can spare. Then:

1. Open `http://localhost:8006` in a browser. This is the guest's console —
   Windows installs itself automatically on first boot; it takes a while.
2. Once it reaches the desktop, you have a normal Windows 11 install logged
   in as the account you set in `USERNAME`/`PASSWORD`.

If you are using `virt-install` instead, install Windows 11 as you normally
would and make sure the guest is reachable on the network (bridged or NAT
with a forwarded SSH port both work — WinBridge only needs a `host`/`port` it
can reach).

## Running `setup-windows.ps1`

First, generate a dedicated key pair on the **Linux host** — do not reuse
your regular SSH key for this:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_winbridge_vm -N ""
cat ~/.ssh/id_winbridge_vm.pub
```

Copy that output. In the VM (via the web console or RDP), open an
**elevated** PowerShell and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\setup-windows.ps1 -PublicKey "ssh-ed25519 AAAA... your-key-here"
```

You will need to get `setup-windows.ps1` into the guest first — copy/paste
its contents through the web console's clipboard integration, or use the
`/storage` volume mount (visible inside the guest as a `Z:` shared drive when
you mount a host folder under `./storage/shared` in `docker-compose.yml`).

The script installs, idempotently:

- Git for Windows
- Visual Studio Build Tools 2022 with the C++ desktop workload (this is what
  `flutter build windows` actually invokes under the hood)
- the Flutter SDK, cloned to `C:\tools\flutter` and added to the machine
  `PATH`
- rsync (via Chocolatey — there is no official winget package)
- OpenSSH Server, started and set to start automatically, with your public
  key authorized

It finishes by printing `flutter --version` so you can confirm the SDK is
actually usable before moving on.

Windows OpenSSH treats an administrator account specially: it only reads
`C:\ProgramData\ssh\administrators_authorized_keys`, never the per-user
`~/.ssh/authorized_keys`, and only if that file's ACLs restrict it to
`Administrators` and `SYSTEM`. The script sets this up for you; if you create
the VM account as a non-administrator, use the per-user file instead and
adjust the script's `$authorizedKeysPath`.

Finally, note the VM's IP or forwarded host/port — `docker compose port
windows 22` shows the forwarded SSH port if you used the compose file above.

## Writing `~/.config/winbridge/vm.json`

```sh
mkdir -p ~/.config/winbridge
cat > ~/.config/winbridge/vm.json <<'JSON'
{
  "host": "127.0.0.1",
  "port": 2222,
  "user": "winbridge",
  "identityFile": "~/.ssh/id_winbridge_vm",
  "remoteWorkspace": "C:/winbridge"
}
JSON
chmod 600 ~/.config/winbridge/vm.json
```

Field notes:

- `host`, `user` — letters, digits, `.`, `_`, `-` only. `winbridge vm doctor`
  rejects anything else with the offending field named, since these values
  end up on the command line WinBridge runs on the VM.
- `port` — defaults to `22` if omitted.
- `identityFile` — optional; omit it to let `ssh` fall back to its own
  default identity or an agent. `~` is expanded against your Linux `$HOME`.
- `remoteWorkspace` — a Windows path, forward slashes are fine
  (`C:/winbridge`). **Create this directory on the VM first** — WinBridge
  syncs your project into a fixed subdirectory of it (`<remoteWorkspace
  >/project`) but does not create `remoteWorkspace` itself. Same restricted
  charset as `host`/`user`, plus no `..`.
- `flutterPath` — optional; only set this if `flutter` is not on the VM's own
  `PATH` for the SSH session (`setup-windows.ps1` puts it there, so you
  normally do not need this).

`XDG_CONFIG_HOME` is honored if you have it set. For scripting or CI,
`WINBRIDGE_VM_CONFIG` overrides the path outright.

WinBridge warns if the file is readable by anyone but you — `chmod 600` it.

## First `winbridge vm doctor`

```sh
dart run bin/winbridge.dart vm doctor
```

On the very first connection to a new VM, `ssh` will refuse the unknown host
key (strict host key checking is on by default — see
[Security notes](#security-notes)). Accept it once, deliberately:

```sh
dart run bin/winbridge.dart vm doctor --accept-new
```

After that, every ordinary `winbridge build` and `winbridge vm status` uses
strict checking again — `--accept-new` never becomes the default and never
silently accepts a *changed* key, only a new one.

A clean run reports `ssh`/`rsync` present locally, the config valid,
connectivity, and remote Flutter and rsync found. Fix whatever it flags
before moving on.

## First Flutter build

```sh
dart run bin/winbridge.dart build path/to/your/flutter/app
```

This syncs the project (skipping `build/`, `.dart_tool/`, `.git/`), runs
`flutter pub get` and `flutter build windows --release` on the VM, then
fetches `build/windows/x64/runner/Release` back into
`build/winbridge/windows-x64/`. The first build is slow — Gradle-style
incremental caching does not carry over between runs unless you keep reusing
the same VM and remote workspace, which the fixed `<remoteWorkspace>/project`
layout is designed to let you do.

## Troubleshooting

**"Host key verification failed" / "REMOTE HOST IDENTIFICATION HAS
CHANGED"** — if you rebuilt the VM (new install, new container), its host
key is genuinely different and this is `ssh` doing its job. Remove the stale
entry from `~/.ssh/known_hosts` (the error message names the exact line), and
either reconnect once with a normal `ssh` command or run `winbridge vm doctor
--accept-new`. Never use `ssh -o StrictHostKeyChecking=no` — WinBridge does
not offer this as an option and never will.

**"MISSING remote flutter"** — `flutter` is not on the SSH session's `PATH`.
`setup-windows.ps1` adds `C:\tools\flutter\bin` to the *machine* `PATH`,
which only takes effect for processes started after that change and after
`sshd` itself restarts (the script restarts it for you). If you moved or
reinstalled Flutter after running the script, set `flutterPath` in
`vm.json` to the full path of `flutter.bat`, or re-run `setup-windows.ps1`.

**Visual Studio Build Tools not found / CMake configure fails on the VM** —
run `flutter doctor -v` inside the VM directly (RDP or the web console). It
names what is missing. The most common cause is the C++ workload not
actually landing — re-run `setup-windows.ps1`, or install it by hand:
Visual Studio Installer → Modify → check "Desktop development with C++".

**Firewall** — the compose file's `2222:22` mapping only helps if something
inside the guest also allows the connection; `setup-windows.ps1` adds the
inbound firewall rule for port 22, but if you changed the sshd port or are
using `virt-install` with a different network setup, check Windows Defender
Firewall → Inbound Rules yourself.

**Sync is very slow or times out** — the first sync of a fresh Flutter
project (with `build/`, `.dart_tool/` excluded) should be small. If it is
not, check you are not accidentally including a populated `build/` directory
from a previous local build — WinBridge's default excludes only cover the
common cases.

## Security notes

- Host key checking is strict by default (`StrictHostKeyChecking=yes`); the
  only relaxation WinBridge offers is `--accept-new` on `vm doctor`/`vm
  status`, which trusts an *unseen* host once and still refuses a *changed*
  one.
- Auth is key-only (`BatchMode=yes`); WinBridge never prompts for or accepts
  a password.
- The VM is treated as semi-trusted: everything it sends back is data that
  gets validated (path containment, no symlinks) before WinBridge touches it
  on the host, never something the host executes.
- Use a VM dedicated to WinBridge builds, not a general-purpose Windows
  machine — the whole point of the design is that a hostile project can only
  ever affect the disposable VM, never your Linux host.
