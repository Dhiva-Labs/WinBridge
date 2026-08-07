# RemoteApp: running what Wine can't

Some Windows software will never run under Wine — a driver-dependent tool, an
app that leans hard on a Windows-only API, something protected in a way that
falls over under translation. For those, WinBridge's answer is not "give up",
it's "run it on real Windows and only show the window here": the M2 headless
Windows VM, driven as a seamless RemoteApp session over FreeRDP.

```sh
winbridge vm app "C:/apps/App/app.exe"
```

This is not Wine. The program executes for real, inside the VM, on real
Windows; FreeRDP just brings its window (and clipboard, and optionally audio)
over to your Linux desktop, so it feels local even though nothing about it
is running on Linux at all.

## What it needs from the VM

The same VM `winbridge build`'s Flutter path uses — see
[`docs/vm-setup.md`](vm-setup.md) for bringing one up, and
`~/.config/winbridge/vm.json` for how WinBridge finds it. RemoteApp reuses
that same config (`host`, `user`, `port`) but talks to the VM over RDP
(`3389`) instead of SSH (the port `vm.json` names) — `scripts/vm/docker-compose.yml`
already publishes `3389` on `127.0.0.1` alongside the SSH port, so a VM set
up per `docs/vm-setup.md` needs nothing extra for this to work.

Before `winbridge vm app` can do anything useful, the target program has to
already be installed *inside* the VM — over RDP or the web console, the same
way you'd install anything else on that Windows machine. `winbridge vm app`
does not install software; it launches something already there.

## Installing an RDP client

`winbridge vm app` looks for a FreeRDP client on your `PATH` — `xfreerdp`,
`xfreerdp3`, `wlfreerdp`, then `sdl-freerdp`, whichever is found first — and
tells you exactly what to install if none are:

```sh
sudo apt install freerdp3-x11   # or freerdp2-x11 on an older distro
```

(`wlfreerdp` is FreeRDP's native Wayland client and `sdl-freerdp` its newer
SDL-based one; either works if that's what your distro packages.) The error
you get when nothing resolves names every candidate that was tried and every
directory searched, the same way every other "tool not found" error in
WinBridge does — see `lib/src/vm/remote_app.dart`'s `RemoteAppToolNotFound`.

## The certificate trade-off: `/cert:tofu`

Every connection uses `/cert:tofu` — trust an unseen certificate once and
remember it, refuse one that changed without a matching new trust. This is
deliberately *not* the same stance WinBridge takes for SSH, where strict host
key checking is the default and `--accept-new` is an explicit opt-in flag.
The reasons are specific to what's on the other end of each connection:

- An SSH host key is (usually) stable for the VM's entire lifetime — it's
  worth defaulting to strict and asking the user to opt into trusting a new
  key once, deliberately.
- An RDP certificate on a `dockur/windows`-style VM is **self-signed and
  regenerated on every fresh Windows install** — which, for a disposable
  build VM you might recreate more than once, is routine rather than
  suspicious. Defaulting to strict checking here would mean every VM rebuild
  demands a manual "yes, trust this" step before `vm app` works again, for a
  VM that is already bound to `127.0.0.1` only (see `docker-compose.yml`) and
  already treated as semi-trusted by every other part of WinBridge that talks
  to it.
- `tofu` is not `/cert:ignore`. A certificate that changes *without* you
  having rebuilt the VM — the actual attack this exists to catch — is still
  flagged, the same way a changed SSH host key still is.

If you want strict behaviour anyway, run the FreeRDP client yourself with
your own certificate policy; `winbridge vm app` does not offer a flag to
weaken `tofu` further, only the option of not using this command at all.

## Passwords: what's supported today, honestly

**No password ever reaches WinBridge's argument vector, full stop** — a
password on a command line is visible to every other process on the machine
via `/proc` or `ps`, which is exactly the kind of leak WinBridge's security
rules exist to prevent everywhere else (see `docs/DESIGN.md`'s security
rules).

The intended safe mechanism is FreeRDP's own `/from-stdin`: type the password
into the terminal, FreeRDP reads it from its stdin, it never touches argv or
disk. WinBridge does not use it yet, because it *can't*, correctly: every
process WinBridge spawns goes through `ProcessRunner`
(`lib/src/core/process_runner.dart`), and that class does not wire a child's
stdin to the terminal at all — there is no parameter for it. Feeding a
password through stdin would need that plumbing to exist first, and adding it
is outside this module's boundary for this milestone.

So, honestly: **`winbridge vm app` works today for VM accounts FreeRDP can
authenticate without an interactive password prompt** — a passwordless
account (reasonable for a disposable build VM already bound to `127.0.0.1`
and nothing else, per `docs/vm-setup.md`'s own security notes), or credentials
FreeRDP has already cached for that host from a prior direct `xfreerdp` run
under your own account. If your VM account needs a password and you haven't
cached one, run the FreeRDP client directly instead of through
`winbridge vm app`.

`WINBRIDGE_RDP_ASK` is reserved for a future interactive-prompt feature, once
`ProcessRunner` can support it. Setting it today does not silently attempt
something insecure or hang waiting on a pipe nobody will ever write to — it
fails immediately with an explanation pointing back here.

## The remote path

The executable path you give `winbridge vm app` is validated with the exact
same charset `vm.json`'s `remoteWorkspace` field is: letters, digits,
`:/_.-`, and no `..` segment. This is a real, known limitation worth stating
plainly: **a path containing a space — including anything under
`C:\Program Files\`, where a great deal of real Windows software actually
installs — is rejected.** Work around it today by installing (or moving) the
target program somewhere without spaces, e.g. `C:\apps\`, inside the VM.
Supporting quoted paths with embedded spaces safely, given that the far end
of the FreeRDP argument itself does its own sub-parsing of the `/app:` value,
is a real piece of work this milestone does not attempt rather than get
partially right.

## Argument shape

```
<client> /v:<host>:<port> /u:<user> /app:program:"<remote path>" /cert:tofu +clipboard [/sound]
```

`/app:program:"<path>"` is FreeRDP3's syntax for naming a specific remote
program instead of opening a full desktop. `+clipboard` redirects the
clipboard both directions — without it, a RemoteApp window would not feel
like a local one at all. `/sound` is opt-in (`--sound`) since audio
redirection is not always wanted.

## Honest limitations

- **No local validation that the app actually launched correctly.** This
  milestone builds and validates the argv WinBridge sends to FreeRDP and
  documents what the VM needs; it does not (and, without a real VM in CI,
  cannot) verify end-to-end that a given app opens a seamless window
  correctly. Treat a clean exit code as "FreeRDP connected and ran the
  command", not as proof the app itself came up successfully — check the VM
  directly (RDP or the web console) the first time you try a given app.
- **Passwords, as above** — passwordless or pre-cached credentials only, for
  now.
- **Paths with spaces are rejected**, as above.
- **No `.desktop` integration.** A RemoteApp window does not (yet) appear in
  your launcher the way `winbridge desktop add` entries do for Wine apps —
  you start it with `winbridge vm app` each time.
