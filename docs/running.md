# Running Windows apps

```sh
winbridge run path/to/app.exe
winbridge run path/to/app.exe -- --some --app-flags
```

That is the whole interface. There is no Wine to install, no prefix to create,
no winecfg to open. The first `winbridge run` downloads the Wine build
WinBridge is pinned to, verifies it, and uses it; every later run just starts.

WinBridge builds Windows binaries and runs them, and the two halves meet here:

```sh
winbridge build ./myapp
winbridge run myapp/build/winbridge/windows-x64/myapp.exe
```

## What happens on a run

1. **The executable is checked.** The same PE32+ header check `winbridge build`
   applies to its own output runs here first, so pointing `run` at a Linux
   binary or a mis-built file says so plainly instead of producing a page of
   Wine loader errors.
2. **The runtime is resolved**, in this order: `WINBRIDGE_WINE` if you set it,
   then the managed runtime, then any `wine` on your `PATH`. If none of those
   exist, the pinned build is downloaded — one line telling you what and where.
3. **The app's prefix is selected** — its own private C: drive.
4. **The app runs** from its own directory, with its output streamed straight
   through. `winbridge run` exits with the app's exit code, so it composes with
   scripts and `&&` like any other command.

## Where things live

| What | Where | Safe to delete? |
| --- | --- | --- |
| Wine runtime | `~/.cache/winbridge/runtimes/<build>/` | Yes — re-downloaded on next run |
| DXVK, winetricks | `~/.cache/winbridge/runtimes/<name>/` | Yes — same |
| App prefixes | `~/.local/share/winbridge/prefixes/<app>/` | Yes, but it is that app's data |

Both honour the XDG variables (`XDG_CACHE_HOME`, `XDG_DATA_HOME`). The split is
deliberate: the runtime is a cache, replaceable from the network. A prefix is
the app's installed state — its registry, its settings, its saved files — so it
lives in your data directory where a cache cleaner will not take it.

Nothing is ever written inside the runtime directory at run time. Every app
writes to its own prefix.

## Prefixes: one per app

Each app gets its own Windows world, named after the executable — `game.exe`
gets `game`, `Setup.exe` gets `Setup`. That isolation is the point: an
installer that wrecks its own registry, or an app that needs some ancient
runtime, cannot reach anything else.

```sh
winbridge prefix list                  # what exists, and which have DXVK
winbridge run app.exe --prefix shared  # put two apps in one world on purpose
```

**Resetting an app is deleting its prefix.** There is no uninstall to run and
no other state to clean up:

```sh
winbridge prefix delete game
```

The next run builds a fresh one. Two apps that must see each other — an
installer and the thing it installed — should share a `--prefix`.

The first run in a new prefix takes noticeably longer: Wine is creating the C:
drive and registry from scratch. It is a one-off per app.

`winbridge run --list-prefixes` still works and prints a deprecation notice;
use `winbridge prefix list`.

## DXVK: faster Direct3D

Wine translates Direct3D to OpenGL. [DXVK](https://github.com/doitsujin/dxvk)
translates it to Vulkan instead, which is usually a large improvement for 3D
applications and games. WinBridge installs it per prefix:

```sh
winbridge run game.exe --dxvk     # install DXVK here and use it
winbridge run game.exe            # ...and from now on, without asking again
winbridge run game.exe --no-dxvk  # back to Wine's own Direct3D
```

The flag is **sticky per prefix**: it sets that app's default rather than
applying to one launch. `winbridge prefix list` shows which prefixes have it
and at what version.

What happens under the hood: the DXVK DLLs (`d3d8`, `d3d9`, `d3d10core`,
`d3d11`, `dxgi`) are copied into the prefix's `system32` and `syswow64`, and
runs get `WINEDLLOVERRIDES` telling Wine to load those instead of its own. If
you already export `WINEDLLOVERRIDES` yourself, yours is appended after ours —
Wine takes the last entry for a given DLL, so your setting wins.

DXVK needs a working Vulkan setup. `winbridge doctor` reports whether a Vulkan
loader is present, and `--dxvk` refuses with an explanation rather than failing
obscurely if there is none. The check is shallow on purpose: it tells you the
loader is installed, not that your graphics driver is configured — that part is
between you and your distribution.

`--no-dxvk` stops the overrides; it leaves the DLLs in the prefix, because the
override is what decides which implementation loads. A prefix you want
genuinely pristine is `winbridge prefix delete` away.

## winetricks: runtimes and tweaks

Some Windows apps need pieces Wine does not ship — a particular Visual C++
redistributable, .NET, core fonts.
[winetricks](https://github.com/Winetricks/winetricks) installs those into a
prefix, and WinBridge runs a pinned copy of it against your Wine:

```sh
winbridge prefix tricks mygame corefonts vcrun2019
winbridge prefix tricks mygame list            # what verbs exist
winbridge prefix tricks mygame list-installed  # what this prefix already has
```

Output streams as it goes — some verbs download a lot and take minutes, and a
silent terminal for that long is indistinguishable from a hang.

**What you are trusting.** WinBridge pins winetricks itself to a tagged release
and checks its SHA-256 before running it. It cannot do the same for what the
*verbs* fetch: those download redistributables from Microsoft and other third
parties at install time, and it is winetricks — not WinBridge — that checksums
them. So `winbridge prefix tricks` extends your trust to winetricks and to
whoever is serving those files. That is the same bargain as running winetricks
directly; it is stated here so it is a decision rather than a surprise. If that
is not a trade you want, skip it: plenty of apps need nothing.

A note on our Wine build: winetricks warns that Wine's wow64 mode is
experimental. WinBridge pins a wow64 build deliberately (it avoids needing
32-bit host libraries), so expect that warning. Verbs that install 32-bit
components are the ones most likely to be affected.

## Console and GUI apps

Both work. A console app's output streams to your terminal and its exit code
becomes `winbridge run`'s, so it pipes and scripts normally:

```sh
winbridge run tool.exe -- --version | grep 1.2
```

A GUI app opens a window on your desktop and `winbridge run` stays in the
foreground until it closes. Wine's own diagnostic chatter is suppressed
(`WINEDEBUG=-all`); `--verbose` lifts that when you need to see what Wine is
doing, along with the resolved runtime path, the prefix, and the exact command.

## Choosing your own Wine

Set `WINBRIDGE_WINE` to a `wine` binary to use it instead of the managed one —
useful for testing a patched build or a distro Wine you already trust:

```sh
WINBRIDGE_WINE=/usr/bin/wine winbridge run app.exe
```

WinBridge verifies the checksum of the runtime it downloads itself, and says so
under `winbridge doctor`. It cannot vouch for a `wine` you pointed it at or one
it found on your `PATH` — those run on your say-so, which is exactly what
choosing them means.

## Honest limitations

Launching apps in isolated prefixes, DXVK and winetricks all work today.
What to know, and what is still missing:

- **DXVK is installed but its rendering is not verified by us.** The install,
  the DLL placement and the overrides are covered by tests that run against a
  real prefix. Actual Direct3D rendering is not: it needs a machine with a
  working Vulkan driver and a 3D application, which the test suite does not
  have. Treat the performance win as expected rather than measured here.
- **No compatibility database.** Whether a given app works is between you and
  Wine; [WineHQ's AppDB](https://appdb.winehq.org/) is the place to check.
  Reporting what you find is genuinely useful — see `CONTRIBUTING.md`.
- **64-bit is the tested path.** The pinned build is a WoW64 build, so 32-bit
  Windows apps should run without any 32-bit libraries on your host, but the
  binaries WinBridge itself produces are 64-bit and that is what is verified.
- **No `.desktop` integration yet.** Apps do not appear in your desktop
  launcher; you start them with `winbridge run`.

If an app does not work, the prefix is disposable — delete it and try again
with different settings before assuming the app is at fault.

## A note on Wine's background server

Wine keeps a `wineserver` process per prefix, and it outlives the app it
served by a few seconds so the next launch is quick. `winbridge run` returns as
soon as *your app* exits and does not wait for it, so the exit code and timing
you see are the app's.

It is worth knowing about in one case: that server inherits the same output
streams, so a tool that waits for a pipe to close rather than for `winbridge
run` to exit can appear to hang for a few seconds after the output is already
there. `winbridge run app.exe | grep x` is unaffected. If you want the session
gone immediately, `wineserver -k` inside the prefix ends it.
