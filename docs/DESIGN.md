# WinBridge design — M1 core

This document is the contract between the CLI core and the toolchain adapters.
If code and this document disagree, that is a bug in one of them; say so.

## Shape of a run

```
winbridge build ./myapp
   │
   ├─ ProjectDetector      what kind of project is this?        → Project
   ├─ ToolchainRegistry    who can build that?                  → Toolchain
   ├─ BuildCommand         create output + cache directories
   ├─ Toolchain.build()    ── ToolResolver ──→ absolute tool path
   │                       ── ProcessRunner ─→ argv, no shell
   │                                          → BuildResult
   └─ verifyArtifacts()    do the claimed artifacts exist, inside the
                           output directory, and pass every verifier?
```

The last step is the point. A toolchain does not get to declare its own
success: it returns paths, and the CLI decides.

## Module map and ownership

| Path | Holds | Owner |
| --- | --- | --- |
| `bin/winbridge.dart` | entry point; sets the exit code and nothing else | core |
| `lib/src/cli/` | command wiring, output formatting, composition root | core |
| `lib/src/core/` | process runner, tool resolver, config, errors, contracts | core |
| `lib/src/detect/` | project detection | core |
| `lib/src/toolchains/` | native cross-compiler adapters | adapters |
| `lib/src/pe/` | PE32+ header verification | adapters |
| `lib/src/vm/` | Windows VM build path (M2) | VM |
| `lib/src/run/` | managed Wine runtime, app prefixes, launching (M4) | core |

`lib/winbridge.dart` exports everything an adapter needs. Import that, not
individual `src/` files:

```dart
import 'package:winbridge/winbridge.dart';
```

`lib/src/cli/` is deliberately not exported. The CLI drives adapters; adapters
never reach back into the CLI.

**The one exception**, because a module that contributes a *subcommand* has to
extend its base class: a feature module may import
`package:winbridge/src/cli/command.dart` for `WinBridgeCommand`, and nothing
else under `lib/src/cli/`. `lib/src/vm/vm_command.dart` does this. In
particular a module must not import `runner.dart` or `toolchain_setup.dart` —
registration flows one way, from the composition root outward.

### Composition root

`lib/src/cli/toolchain_setup.dart` is the single place adapters are registered,
and the only place the CLI may import `lib/src/toolchains/`, `lib/src/pe/` or
`lib/src/vm/`:

```dart
List<Toolchain> registeredToolchains() => [...];
List<ArtifactVerifier> defaultVerifiers() => const [PeVerifier()];
```

Landing an adapter is one line in that list. Order matters — the first
toolchain whose `canHandle` returns true builds the project — so put the
preferred path first. Per the plan's "cheap path first": native cross-compilers
before Wine, Wine before the VM. `FlutterVmToolchain` is registered last for
that reason.

`defaultVerifiers()` is the matching hook for artifact checks. `WinBridgeRunner`
takes both as nullable constructor parameters and falls back to these, so tests
can substitute an empty registry or skip PE verification without reaching into
global state.

A subcommand contributed by a feature module is wired the same way, by
`addCommand` in `WinBridgeRunner`'s constructor.

## The Toolchain contract

```dart
abstract class Toolchain {
  String get id;
  String get description;
  bool canHandle(Project project);
  List<ToolRequirement> requirements();
  Future<BuildResult> build(BuildRequest request);
}
```

- **`id`** — stable, lowercase: `go`, `rust`, `dotnet`, `zig-cc`, `vm`. It
  appears in output, in error messages, and as a cache directory name, so
  changing it later invalidates caches.
- **`description`** — one line, shown by `doctor` and `detect`.
- **`canHandle`** — pure and cheap. It is called for every registered toolchain
  on every build. No I/O.
- **`requirements`** — called by `doctor` with no project in scope. Must not
  perform I/O and must not throw.
- **`build`** — see below.

```dart
class ToolRequirement {
  const ToolRequirement({
    required this.tool,
    required this.reason,
    this.alternatives = const [],
    this.optional = false,
  });

  final String tool;
  final String reason;
  final List<String> alternatives;
  final bool optional;

  List<String> get candidates => [tool, ...alternatives];
}
```

`reason` is read by a human staring at a broken machine. Write
`'cross-compiles Go for windows/amd64'`, not `'go binary'`.

`alternatives` covers a requirement with several acceptable providers — the C
toolchain accepts `zig` or `x86_64-w64-mingw32-gcc`. `optional: true` means
`doctor` reports it as absent without failing; use it for tools that unlock
extra capability (cgo linking) rather than gate the build.

## BuildRequest

```dart
class BuildRequest {
  final Project project;
  final String outputDirectory;   // absolute, already created
  final String cacheDirectory;    // absolute, already created
  final BuildTarget target;       // windows-x64 | windows-arm64
  final BuildMode mode;           // debug | release
  final List<String> extraArguments;
  final ProcessRunner runner;
  final ToolResolver tools;
  final Output output;
}
```

An adapter is given its `runner`, `tools` and `output` rather than reaching for
globals, and that is what makes the security rules checkable: an adapter with no
`ProcessRunner` of its own cannot spawn anything, and one with no `ToolResolver`
of its own cannot bypass the managed-toolchain search order.

- **`outputDirectory`** already exists when `build` is called. It is the only
  directory in the project tree an adapter may write to.
- **`cacheDirectory`** already exists, under `~/.cache/winbridge/build/<id>`.
  Point compiler caches here (`GOCACHE`, `CARGO_TARGET_DIR`, object files) so
  builds do not litter the user's source tree.
- **`extraArguments`** are argv elements from the user's command line, appended
  after the adapter's own arguments. Never join them into a string, never
  re-split them.
- **`target.arch`** is real. `windows-arm64` is a supported Go and Rust target;
  if an adapter cannot serve a target, return a failure saying so.

## BuildResult

```dart
class BuildResult {
  const BuildResult.success({
    required List<String> artifacts,
    String? summary,
    Duration? duration,
  });

  const BuildResult.failure(
    String message, {
    String? details,
    Duration? duration,
  });

  final bool succeeded;
  final List<String> artifacts;
  final String? summary;
  final String? failureMessage;
  final String? details;
  final Duration? duration;
}
```

**Return a failure; do not throw.** A compiler exiting non-zero, an
unsupported target, a missing project file — those are build outcomes, so
return `BuildResult.failure`. Put the compiler's own output in `details`; the
CLI prints it beneath the message. Use `ProcessRunner.run` (not `runOrThrow`)
where you intend to inspect the exit code yourself.

Throwing is for things that are not a build outcome: `ToolNotFound` from the
resolver, or a bug. Both are handled by the CLI.

**Artifacts are paths, and every one is checked.** For each entry the CLI
requires that it is absolute, that it exists, that it is a regular file, and
that it sits strictly inside `outputDirectory` once symlinks are resolved. A
success carrying an empty `artifacts` list is rejected — silence is not proof of
a build. Put the primary artifact (the `.exe`) first; DLLs, PDBs and bundle
files follow.

`summary` is one verbose-mode line, e.g. `go 1.26.5, windows/amd64`.

## Tool resolution

```dart
ResolvedTool? resolve(String name);              // null if absent
ResolvedTool? resolveAny(Iterable<String> names);
String        requirePath(String name, {String? reason});   // throws
ResolvedTool  requireAny(List<String> names, {String? reason});
```

Search order, first hit wins:

1. `WINBRIDGE_TOOLCHAIN_DIR`, expanded to its `*/bin` subdirectories.
2. `~/.cache/winbridge/toolchains/*/bin` — the managed, no-sudo installs.
   Honours `XDG_CACHE_HOME`.
3. `PATH`, in its own order.

Managed installs deliberately outrank `PATH` so a developer who bootstrapped a
pinned toolchain gets that one, not whatever a system package happens to
provide. This is what makes the no-sudo story work: nothing has to be installed
system-wide and no shell profile is edited.

Details worth knowing:

- Both toolchain roots expand as `<root>/<toolchain>/bin`, sorted, so the order
  never depends on filesystem enumeration order.
- Relative `PATH` entries are skipped. They resolve against whatever directory
  the user happened to be in, which is a classic hijack.
- A candidate must be a regular file with an execute bit; directories and
  non-executable files are skipped.
- `resolve` takes a bare name. Passing a path throws `ArgumentError`.
- `resolveAny` is **name-first**: it searches the whole path for the first name
  before trying the second. `resolveAny(['zig', 'gcc'])` prefers a `zig`
  anywhere over a `gcc` in the managed cache.
- Results are cached per resolver instance and are always absolute.

## Process execution

```dart
Future<RunResult> run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String> environment = const {},
});

Future<RunResult> runOrThrow(..., {String? what});
```

`ProcessRunner` is the only place in the package that touches `Process`, always
with `runInShell: false`. There is no code path that assembles a command string,
so no project name, path, flag or filename can be interpreted as shell syntax.

- **`executable` must be an absolute path.** A bare name would be resolved by
  the OS against the ambient `PATH`, silently defeating the search order above.
  Get the path from `ToolResolver`.
- **`environment` is an additive overlay** on the parent environment. Keys are
  validated; malformed names throw.
- **Environment values are never logged.** Verbose mode prints overlay *keys*
  only. Nothing else may print a value either — that rule is what keeps a token
  in the environment out of the terminal and out of CI logs.
- `stdout` and `stderr` are captured verbatim and byte-exact, so a version
  string can be parsed from them. In verbose mode complete lines are also
  streamed as they arrive.
- `RunResult.commandLine` is display only. Nothing parses it back and it never
  reaches a shell.

## Detection

```dart
Project? detect(String directory);
```

Detection looks at the given directory only. It does not recurse and does not
walk up to a repository root, so a monorepo is built one package directory at a
time and the same directory always yields the same answer.

| Precedence | Marker | Type |
| --- | --- | --- |
| 1 | `pubspec.yaml` declaring a flutter dependency | `flutter` |
| 2 | `go.mod` | `go` |
| 3 | `Cargo.toml` | `rust` |
| 4 | `*.csproj`, `*.fsproj` | `dotnet` |
| 5 | `CMakeLists.txt`, then `Makefile`, then `*.c`/`*.cpp`/`*.cc`/`*.cxx` | `c` |

The order runs from the most specific marker to the least. A `pubspec.yaml`
pulling in Flutter can mean nothing else; a `Makefile` is a weak hint that
plenty of Go and Rust projects also carry. So a Go project with a Makefile is
Go, and a Flutter app with a `windows/` CMake tree is Flutter.

A `pubspec.yaml` *without* Flutter is not a match at all — plain Dart has no
Windows cross-compile path, and claiming one would be worse than saying nothing.

`Project` carries evidence for every type that matched, ordered by precedence
with the winner first, so `detect` can explain an ambiguous directory rather
than just asserting an answer.

### `Project.name` is a safe file-name component

Adapters build output names out of it (`'${project.name}.exe'`), but the
declared name is read from the project's own `pubspec.yaml`, `Cargo.toml` or
`go.mod` — files a hostile repository controls. A manifest declaring
`name: ../../../../etc/cron.d/x` would otherwise steer a compiler's `-o`
outside the output directory, and the compiler writes there *before* any
verification runs.

So `Project` guarantees its `name` satisfies `isSafeNameComponent`: non-empty,
not `.` or `..`, no path separators, no control characters, none of the
characters Windows rejects in a file name, and no leading `-` (a name is
routinely spliced into argv, where a leading dash reads as a flag). A declared
name that fails any of those is replaced with the directory name.

Adapters may use `project.name` in a path without sanitising it again. They
should still not use it as a *remote* shell token — see the VM section, where
the checkout directory is a fixed literal for exactly this reason.

## Errors and exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | build or tool failure |
| 2 | usage error |
| 141 | the reader of our stdout went away (`... \| head`) |

141 is `128 + SIGPIPE`, what a shell reports for a process it killed on a
closed pipe, so `winbridge detect | head -1` behaves like any coreutils
command. Dart disables `SIGPIPE` and surfaces `EPIPE` instead — and it does so
*asynchronously*: `io.stdout` performs its writes inside a stream callback, so
the error is delivered to the enclosing zone and no `try`/`catch` around
`writeln` can see it. Two consequences, both of which matter if you touch the
output plumbing:

- `WinBridgeRunner.execute` runs the command inside a `runZonedGuarded` and
  flushes stdout before returning, so a deferred pipe error becomes an exit
  code rather than an unhandled exception arriving after `main` has finished.
- The real `io.stdout`/`io.stderr` are resolved **lazily**, on first write, by
  both `Output` and the runner. Touching `io.stdout` binds its internal
  subscription — and therefore where its write errors are delivered — to
  whatever zone is current at that moment. Resolving it in a constructor binds
  it outside the guarded zone, and the guard then silently stops working.

`Output` additionally retires a sink after its first broken-pipe error, so a
half-closed pipeline (`winbridge build 2>err.log | head`) still gets its
diagnostics on the stream that is still open. Any *other* write failure is a
bug and still propagates.

Everything user-facing extends `WinBridgeException` and carries a `message`, an
optional `details` block, and its own exit code: `UsageFailure` (2),
`DetectionFailure`, `ToolNotFound`, `BuildFailure`, `ProcessFailure`,
`ArtifactFailure` (all 1).

`WinBridgeRunner.execute()` renders these as a clean message and returns the
exit code. Anything *not* in that hierarchy is a bug and prints as one — a stack
trace with `--verbose`. Prefer `execute` over `run` in any embedder so failures
are reported identically everywhere.

Write messages that name the thing that failed and, where useful, what was
tried. `ToolNotFound` lists every directory it searched, which turns "command
not found" into something a user can act on.

An adapter may catch a `WinBridgeException` raised by its own steps and return
it as a `BuildResult.failure` instead — the VM path does this so a config or
transport error arrives labelled with the step that hit it. That is safe
because the hierarchy is only ever thrown deliberately: a genuine bug is an
`Error` or a plain `Exception` and still escapes as a stack trace. Do not widen
such a catch to `Exception` or `Object`, which would swallow bugs.

### Diagnostic commands

`doctor` and `vm doctor` are reports, but they are also CI gates, so both
follow one rule: **exit 1 when something required is missing, 0 when the path
being checked can actually run.**

- `winbridge doctor` exits 1 if any registered toolchain has an unresolved
  non-optional `ToolRequirement`. An `optional: true` requirement is reported
  as `absent` and never changes the exit code.
- `winbridge vm doctor` exits 1 if any of its checks fail: local `ssh`/`rsync`,
  config validity, connectivity, remote Flutter, remote rsync.

The consequence worth knowing: on a machine set up only for Go, `winbridge
doctor` still exits 1, because the Rust and .NET paths genuinely cannot run.
The report names which tools are missing; a zero exit means every registered
path works, not merely the one you happen to care about.

## Security rules

These are gates, not preferences. `test/core/no_shell_test.dart` enforces the
first two by reading the source, so a violation fails the suite rather than
waiting for review.

1. **argv only.** No shell, ever. `ProcessRunner` is the only file permitted to
   reference `Process`; `runInShell: true`, `sh -c` and `bash -c` appear nowhere
   in the tree.
2. **No spawning outside `ProcessRunner`.** An adapter that needs a process uses
   `request.runner`. It must not import `dart:io`'s `Process`.
3. **No writes outside the sanctioned directories.** An adapter writes to
   `request.outputDirectory` and `request.cacheDirectory` and nowhere else. Not
   the source tree, not `$HOME`, not `/tmp`.
4. **Artifacts are returned, not asserted.** Adapters return paths; the CLI
   verifies existence and containment. Path validation resolves symlinks, so a
   link inside the output directory pointing elsewhere is rejected.
5. **Never log environment values.** Keys only. This applies to `Output` as much
   as to `ProcessRunner`.
6. **Nothing executable comes from the project being built.** Do not read a
   command, script path, or argv fragment out of a project file and run it. A
   hostile repository must not be able to run code on a developer's machine
   through `winbridge build`.
7. **Config is declarative data.** `WinBridgeConfig` holds names, directories
   and defaults. If an on-disk config format is added later it keeps that
   property: no hooks, no scripts.

## Extension seams

**PE verification** (`lib/src/pe/`) plugs in as an `ArtifactVerifier`:

```dart
abstract class ArtifactVerifier {
  String get name;
  Future<void> verify(String artifactPath);   // throws ArtifactFailure
}
```

Verifiers are composed by the CLI and passed to `WinBridgeRunner`, never by
adapters — a toolchain does not vouch for its own output. They run after the
path rules pass, over every artifact. Throw `ArtifactFailure` with a message
naming what was found instead ("not a Windows executable: ELF 64-bit").

**Running apps** (`lib/src/run/`, M4) is the one part of the tree that is not
about producing a binary, so it sits outside the `Toolchain` contract entirely:
there is no project, no build request, no artifact. It is reached only from
`RunCommand`, and it reuses three things from elsewhere.

- `lib/src/pe/`'s `validatePeHeader`, to answer "is this even a Windows
  program" before Wine is asked to run it. This is the second sanctioned
  importer of `lib/src/pe/` alongside the composition root — a header check is
  a pure function over bytes, and duplicating it to preserve a layering rule
  would be worse than the rule is worth.
- `isSafeNameComponent` from `lib/src/detect/`, for prefix names. Same
  guarantee, same reason: a prefix name becomes a directory, and it comes from
  either a file name on disk or the command line.
- `ProcessRunner`, like everything else. `run` passes `streamOutput: true` and
  `captureOutput: false`, which is what that pair of flags exists for: the
  child's output is the user's goal rather than diagnostics about a build, and
  an app that runs for an hour must not accumulate its output in memory.

**Trust in the runtime.** `WineRuntime` resolves in a fixed order —
`WINBRIDGE_WINE`, then the managed runtime, then `PATH` — and only the managed
one is verified. A managed runtime is usable only if it carries a
`.winbridge-verified` stamp naming the pinned checksum, which is written after
verification and before the directory is moved to its final path. So an
interrupted install, or a directory someone dropped there by hand, is ignored
rather than run. The other two paths are the user's explicit choice and are
trusted on that basis; `doctor` says which case a machine is in.

Installation verifies the checksum **before** unpacking — a mismatched archive
is deleted and `tar` never sees it — extracts into a scratch directory beside
the destination, and publishes with a single rename, so a runtime directory is
either absent or complete.

**The VM path** (`lib/src/vm/`, M2) implements `Toolchain` like any other
adapter, registered last so native cross-compilers win. Two things follow from
the rules above:

- Artifacts fetched back from the VM are external input. They land inside
  `request.outputDirectory` and go through the same verification as a local
  build — `requireInside` already refuses absolute paths and `..` traversal, so
  a malicious or broken archive cannot write outside the output directory.
- The VM is semi-trusted. Its output is data, never something the host executes.

The transport belongs behind an interface with a fake for tests, per the plan's
testing policy. Everything it spawns on the host — `ssh`, `scp`, `rsync` — still
goes through `request.runner` with an argv list.

## Landing an adapter

1. Implement `Toolchain` in `lib/src/toolchains/<name>.dart`.
2. Add it to `registeredToolchains()`.
3. Unit-test command construction: given a `Project` and a `BuildRequest`,
   assert the exact argv your adapter builds. That is the test that catches an
   injected argument or a lost flag.
4. Add an integration test that produces a real `.exe` and skips gracefully when
   the toolchain is absent locally.
5. `dart analyze` clean, `dart test` green.

A worked example — the Go adapter's core, verified end to end against the
bootstrapped `go1.26.5`, producing a real PE32+ binary:

```dart
final go = request.tools.requirePath('go');
final exe = p.join(request.outputDirectory, '${request.project.name}.exe');

final result = await request.runner.run(
  go,
  [
    'build',
    if (request.mode.isRelease) ...['-ldflags', '-s -w'],
    '-o', exe,
    ...request.extraArguments,
    '.',
  ],
  workingDirectory: request.project.root,
  environment: {
    'GOOS': 'windows',
    'GOARCH': request.target.arch == TargetArch.arm64 ? 'arm64' : 'amd64',
    'CGO_ENABLED': '0',
    'GOCACHE': p.join(request.cacheDirectory, 'go-build'),
  },
);

if (!result.ok) {
  return BuildResult.failure('go build failed', details: result.diagnostics);
}
return BuildResult.success(artifacts: [exe], summary: 'go ${request.target}');
```
