# Contributing to WinBridge

WinBridge exists so that anything you can do on Windows, you can do from
Linux — on anyone's hardware. Contributions that widen that coverage are the
most valuable thing you can send, whether they're code, docs, or a report
that something does or doesn't work on your machine.

## Reporting hardware results

You don't need to write code to help. If you tried WinBridge with your
printer, USB device, or GPU setup, open a hardware report issue (template
provided) with the device, its `vendor:product` id from `lsusb`, and what
worked natively versus what needed the VM. These reports become the
compatibility list that saves the next person the experiment.

## Development setup

```
dart pub get
dart analyze --fatal-infos
dart test
```

The Dart SDK is the only hard requirement. Cross-compile integration tests
resolve toolchains from `PATH` and `~/.cache/winbridge/toolchains/*/bin` and
skip cleanly when a toolchain is absent — CI runs the full matrix, so a
partial local setup is fine.

## What a change needs before it merges

- `dart analyze --fatal-infos` clean and `dart test` green.
- New behavior comes with tests. Anything touching a network, a VM, or
  another process is behind an interface with a fake for tests.
- The security rules in PLAN.md hold everywhere: processes are spawned from
  argv lists (never a shell string), paths from external sources are
  validated, and nothing relaxes SSH host-key checking below `accept-new`.
- Components may be written in whatever language fits (see the polyglot
  principle in PLAN.md), but they talk to the rest of the system through
  processes, files, and JSON, and they ship with their own tests.

## Docs standards

Documentation never assumes a hardware vendor or system layout. Name the
trade-offs plainly — an honest "this configuration is a poor fit" beats an
overpromise that costs a user an afternoon.
