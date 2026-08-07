# WinBridge compatibility recipes

A recipe is a small JSON file that tells `winbridge recipe apply` what an
installer needs to run well under WinBridge's managed Wine: which winetricks
verbs to install, which DLLs to override, and whether to turn DXVK on. That's
it. **A recipe is data, never code.** The loader (`lib/src/recipes/`) parses
JSON and nothing else — it never executes a byte of what a recipe file
contains. That is a security property, not a style choice: a recipe you
downloaded from a stranger's pull request can be reviewed as data, the same
way you'd review any other JSON, without needing to trust it the way you'd
trust a script.

## Where recipes live

1. **Bundled** — this directory, shipped with WinBridge itself.
2. **User** — `~/.local/share/winbridge/recipes` (honours `XDG_DATA_HOME`).
   Anything you drop here overrides a bundled recipe of the same `id`, so you
   can patch a recipe locally before it lands upstream, or add one for an app
   nobody has contributed yet.

`winbridge recipe list` shows both, and where each recipe actually came from.

## The format

```json
{
  "id": "some-app-1.2",
  "match": { "sha256": "<64 lowercase hex characters>" },
  "apply": {
    "tricks": ["corefonts", "vcrun2019"],
    "dllOverrides": { "d3d9": "n" },
    "dxvk": false
  },
  "notes": "free text for a human",
  "source": "https://example.com/where-you-learned-this"
}
```

### `id` (required)

A stable slug: letters, digits, `.`, `-`, `_`, no leading dash, no path
separators (the same rule WinBridge uses for prefix names and project names —
see `isSafeNameComponent` in `lib/src/detect/project.dart`). Once a recipe
ships, treat its `id` as permanent — a user recipe overriding it by id would
silently stop matching if you renamed it.

### `match` (required) — exactly one of two shapes

**Preferred, and authoritative — a sha256 digest:**

```json
"match": { "sha256": "9c538924110a7cdef871ca36dee218c0774124374ffdeb38af4b76be55bdf7c2" }
```

Get this from the installer itself: `winbridge recipe show path/to/Setup.exe`
prints it (streamed through `sha256sum`, never loaded whole into memory — an
installer can be gigabytes). A sha256 match is exact: it identifies one
specific build of one specific installer, byte for byte.

**Fallback — a file name and exact size, in bytes:**

```json
"match": { "fileName": "Setup.exe", "sizeBytes": 48213504 }
```

For an installer you recognise by name and size but have not (yet) hashed
yourself — maybe you're transcribing what someone reported in an issue rather
than fingerprinting a file you have on disk. This is weaker: two different
builds of an installer are routinely shipped under the identical file name
and, less often, even the same size. **When both a sha256 recipe and a
fileName+sizeBytes recipe could apply to the same file, the sha256 recipe
always wins** — the matcher checks every sha256-keyed recipe before it looks
at any fallback one, regardless of which is listed first or which was loaded
more recently. Treat the fallback shape as a stopgap on the way to a real
fingerprint, not a permanent substitute for one.

Never fabricate a sha256 for software you have not actually hashed. If you
only know a file name and a rough size, use the fallback shape honestly
instead of inventing a hash that looks verified but isn't.

### `apply` (optional — omit it, or leave every field out, for a recipe that
just documents "this one needs nothing special")

- **`tricks`** — a list of winetricks verbs, applied in the order listed via
  `winbridge prefix tricks`'s own machinery. Each verb is validated against
  winetricks' own naming rule, `^[a-z0-9._+][a-z0-9._+-]*$` — lowercase
  letters, digits, `.`, `_`, `+`, `-`, never starting with `-` (a leading dash
  reads as a flag to whatever receives it). `winbridge prefix tricks <name>
  list` shows what winetricks actually offers.
- **`dllOverrides`** — a map of DLL name (lowercase, `^[a-z0-9._-]+$`, no
  `.dll` suffix — `"d3d9"`, not `"d3d9.dll"`) to a `WINEDLLOVERRIDES` value.
  Only five values are accepted, `WINEDLLOVERRIDES`'s own closed set: `"n"`
  (native), `"b"` (builtin), `"n,b"` (native, falling back to builtin),
  `"b,n"` (builtin, falling back to native), or `""` (disabled entirely).
  Anything else is rejected at load time.
- **`dxvk`** — `true` to install and enable [DXVK](https://github.com/doitsujin/dxvk)
  the same way `winbridge run --dxvk` does, `false` (the default) to leave
  Wine's own Direct3D in place.

### `notes` and `source` (both optional)

Free text for the next human, shown by `recipe show`. Never validated beyond
"is this actually a string" and never spliced into anything that runs —
that's the whole point of recipes being data. Use `source` to say where the
combination came from: a WineHQ AppDB entry, a forum thread, your own testing.

## What `recipe apply` actually does

1. Fingerprints the installer and finds the matching recipe (or stops if
   there isn't one — `recipe show` first if you're not sure).
2. Resolves (installing if needed) the same managed Wine `winbridge run`
   uses.
3. Runs the listed winetricks verbs, in order, through the same code
   `winbridge prefix tricks` uses. Stops immediately if a verb fails.
4. Installs DXVK if `dxvk: true`, through the same code `--dxvk` uses,
   refusing with an explanation if this machine has no working Vulkan setup.
5. Records `dllOverrides` against the prefix, so later runs of that prefix
   can compose them into `WINEDLLOVERRIDES` the same way DXVK's own overrides
   are sticky per prefix.

A recipe with an empty (or absent) `apply` block is valid — it documents "this
app just works, no changes needed" — and `apply` becomes a no-op report
rather than touching the prefix at all.

## Contributing a recipe

1. Run `winbridge recipe show path/to/the/installer.exe` to get its real
   sha256.
2. Work out what the app actually needs — winetricks verbs, overrides, DXVK —
   the same way you would by hand with `winbridge prefix tricks`.
3. Write the JSON file (see `template.json` in this directory for a
   documented starting point) and drop it in this directory or, to try it
   locally first, in `~/.local/share/winbridge/recipes/`.
4. Open a pull request adding the file. Recipes are reviewed like any other
   change — a hostile verb, a bad DLL name or an invalid override value is
   rejected by validation before it can ever be applied, but a *plausible but
   wrong* combination (installs the wrong redistributable, turns on DXVK for
   an app that doesn't need it) is a review problem, not a validation one, so
   say in the PR description what you actually tested.

## Reporting how an app ran

Recipes cover *what to apply before running an app*; they do not track
*whether the app then actually worked*. For that — "I tried this app, here is
what happened" — use the hardware-report issue template
(`.github/ISSUE_TEMPLATE/hardware_report.md`), which is what M6's published
compatibility list is meant to be built from. Recipes and compatibility
reports are deliberately separate: a recipe you can review as inert data
before it ever runs; a report is just someone's account of what they saw.

## What recipes cannot do

- **They cannot run anything on their own.** Every value in `apply` is
  validated against a closed pattern or set before it is used; nothing here
  reaches an argument vector unchecked.
- **They are not a compatibility database.** A recipe existing for an
  installer says nothing about whether the app runs well — only what settings
  someone found useful. [WineHQ's AppDB](https://appdb.winehq.org/) is still
  the place to check general compatibility.
- **The fallback match is not a fingerprint.** Treat a `fileName`+`sizeBytes`
  recipe as "probably this installer", not "definitely this installer".
