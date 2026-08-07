# WinBridge compatibility list

What's known to work, what needed WinBridge's VM path, and what doesn't —
sourced from what this repository has actually verified, plus what the
community reports. No app is silently assumed to work: a row without a
report is a row that doesn't exist yet.

## How a row gets here

1. Run the app with WinBridge — `winbridge run`, `--dxvk`, `prefix tricks`,
   or the VM path — and see what happens.
2. Open a [hardware report issue](
   https://github.com/Dhiva-Labs/WinBridge/issues/new?template=hardware_report.md).
   `winbridge report` (see `docs/distribution.md`) prints a filled-in copy of
   that template from your machine's own state — OS/kernel, GPU, Vulkan,
   Wine and prefix status — that you can paste in and add your own app
   notes to. Nothing it gathers is sent anywhere on its own; you choose what
   to paste and where.
3. A maintainer reviews the report and merges a row here, or asks a
   clarifying question first if the report is ambiguous (e.g. "works" but no
   detail on which parts).

**"maintainer-verified" below means run in this repository's own test
suite** — see the file named in each row's Notes column — **not that
WinBridge's authors tested it on a variety of hardware.** Everything else
in a future version of this table will carry a reporter's name or handle
instead, and mean exactly and only what that person reported.

## Table

| App | Works via | Recipe/notes | Reported by |
| --- | --- | --- | --- |
| `fixtures/hello_c` (this repo's own C smoke-test fixture) | Native cross-compile (`zig`/MinGW) + `winbridge run`, managed Wine, no DXVK | Built, launched under the managed Wine runtime in an isolated prefix, and its stdout and exit code checked end to end. See `test/run/run_integration_test.dart`. | maintainer-verified |
| `fixtures/hello_c`, with `--dxvk` | Native cross-compile + `winbridge run --dxvk` | DXVK installs cleanly into a real prefix (DLLs placed, overrides composed) and the app still runs afterward. **Direct3D rendering itself is not verified** — `hello_c` is a console program and there is no GPU with a working Vulkan driver in the environment these tests run in. Installing DXVK is proven; that a Direct3D app actually renders faster or at all through it is not. See `test/run/dxvk_integration_test.dart` and `docs/running.md`'s "Honest limitations" section, which says the same thing in the user-facing docs. | maintainer-verified |

That's the whole table today. It grows from hardware reports, not from
assumptions about what "should" work — see the process above.

## What a row deliberately does not claim

- A row for one app on one machine says nothing about a different app, or
  the same app with different settings (`--dxvk` vs not, different
  winetricks verbs, a different prefix). Compatibility here is per
  configuration, not per app in the abstract.
- "Works via the VM" means the *build* path (M2) or the FreeRDP RemoteApp
  path (M5) got the app running, not that every feature of the app was
  exercised.
- Nothing in this table is a claim about performance, only about whether
  something ran and did what it was supposed to.

See `docs/running.md` for what "works today" means in more general terms
(prefixes, DXVK, winetricks), and `docs/devices.md` for the hardware side
(printers, USB, GPUs) this table doesn't cover — that's a decision path,
not a table, because so much of it is "check the native Linux path first."
