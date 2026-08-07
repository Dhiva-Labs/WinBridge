# Compatibility recipes

Some Windows installers need a little help before they run well: a Visual C++
redistributable, a particular `WINEDLLOVERRIDES` entry, DXVK turned on. A
recipe is a small JSON file that writes that knowledge down once so nobody
has to rediscover it — and because it is JSON rather than a script, it can be
reviewed as data before it is ever applied.

```sh
winbridge recipe show path/to/Setup.exe   # what would apply, if anything
winbridge recipe apply path/to/Setup.exe  # actually apply it
winbridge recipe list                     # what's available, and from where
```

The format itself, how to contribute one, and what recipes cannot do are all
in [`recipes/README.md`](../recipes/README.md) — that file ships with every
install and is the version worth trusting. This page covers the commands.

## `recipe show`

```sh
winbridge recipe show Setup.exe
```

Fingerprints the file — a streamed sha256 (via `sha256sum`; the file is never
read into memory whole, which matters once an installer is gigabytes) plus its
size — and reports whether a recipe matches, and if so exactly what `apply`
would do: the winetricks verbs, the DLL overrides, whether DXVK would be
installed. Nothing is written or run. This is also how you get the sha256 to
put in a recipe you're contributing.

## `recipe apply`

```sh
winbridge recipe apply Setup.exe
winbridge recipe apply Setup.exe --prefix mygame
```

Finds the matching recipe the same way `show` does, then actually applies it
to a prefix — the same per-app prefix `winbridge run` would use for that
executable, or one named with `--prefix`. Each step prints before it runs:

1. Winetricks verbs, in the order listed, through the same code
   `winbridge prefix tricks` uses.
2. DXVK, through the same code `winbridge run --dxvk` uses, if the recipe
   calls for it — refusing with an explanation if this machine has no
   Vulkan loader, exactly like `--dxvk` does.
3. Recording any `dllOverrides` against the prefix.

**Stops at the first failing step.** Nothing after it runs, and nothing
already applied is rolled back — a prefix is disposable
(`winbridge prefix delete`) if you want to start over cleanly.

A recipe with nothing in its `apply` block (documenting "this app just
works") reports that and does nothing further — `apply` never touches a
prefix it has nothing to do to.

If no recipe matches, `apply` fails with the installer's sha256 in the error,
so you can go write one.

## `recipe list`

Shows every recipe WinBridge can currently see — bundled and from your own
`~/.local/share/winbridge/recipes` — with which directory each came from and
how it matches (sha256 or the fileName+sizeBytes fallback). A recipe file
that failed to load (bad JSON, a value that didn't pass validation) is
reported as a warning rather than silently skipped, so a typo in your own
`~/.local/share/winbridge/recipes/mine.json` doesn't just quietly vanish.

## Where recipes are looked for

Bundled recipes come from `recipes/` next to the WinBridge install; set
`WINBRIDGE_RECIPES_DIR` to point somewhere else explicitly (useful for
packaging, or for trying out a whole alternate recipe set). User recipes come
from `~/.local/share/winbridge/recipes` (honouring `XDG_DATA_HOME`) and
override a bundled recipe sharing its `id`.

## Sticky `dllOverrides`, and what still needs wiring

DXVK's own overrides are sticky per prefix — turn `--dxvk` on once and every
later `winbridge run` in that prefix keeps using it. `recipe apply` records a
recipe's `dllOverrides` the same way, in a small per-prefix marker file, so
the mechanism is ready — but as of this milestone `winbridge run` itself does
not yet read that marker back into `WINEDLLOVERRIDES`. Composing it is one
call to `recipeDllOverrides()` from `lib/src/recipes/recipe_apply.dart`,
chained the same way `run_command.dart` already chains `dxvkDllOverrides()`;
see that module's doc comments for the exact shape. Until that lands, a
recipe's DLL overrides take effect for the `recipe apply` run itself (where
relevant — mainly DXVK, which composes its own overrides directly) but are
not yet automatically reapplied by a later plain `winbridge run` in that
prefix.

## Security notes

- **Recipes never execute anything.** The loader parses JSON; nothing in a
  recipe file is ever run as code. Every value that does reach a command line
  — winetricks verbs, DLL names, override values — is checked against a
  strict pattern or a closed set before that happens, and a recipe failing
  validation is reported and skipped, never partially applied.
- **`recipe apply` extends the same trust `winbridge prefix tricks` already
  does.** Winetricks verbs it runs download third-party redistributables that
  winetricks itself checksums, not WinBridge — see docs/running.md's note on
  this for the full trade-off; it applies identically here.
- **The fallback match is a heuristic, not a fingerprint.** A
  `fileName`+`sizeBytes` recipe can match an installer that merely happens to
  share a name and size with a different build. When a sha256-keyed recipe
  exists for the same file, it always wins over the fallback.
