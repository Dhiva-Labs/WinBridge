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
winbridge run --list-prefixes          # what exists
winbridge run app.exe --prefix shared  # put two apps in one world on purpose
```

**Resetting an app is deleting its prefix.** There is no uninstall command and
no other state to clean up:

```sh
rm -rf ~/.local/share/winbridge/prefixes/game
```

The next run builds a fresh one. Two apps that must see each other — an
installer and the thing it installed — should share a `--prefix`.

The first run in a new prefix takes noticeably longer: Wine is creating the C:
drive and registry from scratch. It is a one-off per app.

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

This is the first slice of the "run Windows apps" half of WinBridge. What
works today is launching an app in an isolated prefix. What is not here yet:

- **No DXVK.** Direct3D goes through Wine's OpenGL translation, which is
  markedly slower for 3D games. DXVK — D3D9/10/11 over Vulkan — is the next
  slice.
- **No `.desktop` integration.** Apps do not appear in your launcher; you start
  them with `winbridge run`.
- **No winetricks.** Apps needing extra runtimes (a specific .NET, a VC++
  redistributable) have no supported way to get them yet.
- **No compatibility database.** Whether a given app works is between you and
  Wine; [WineHQ's AppDB](https://appdb.winehq.org/) is the place to check.
  Reporting what you find is genuinely useful — see `CONTRIBUTING.md`.
- **64-bit is the tested path.** The pinned build is a WoW64 build, so 32-bit
  Windows apps should run without any 32-bit libraries on your host, but the
  binaries WinBridge itself produces are 64-bit and that is what is verified.

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
