# Contributing to Dispatch

Thanks for helping with Dispatch. Please open an issue before a large change so
the expected behavior and test plan are clear.

## Start here

- Read [AGENTS.md](AGENTS.md) and [ADR 0001](docs/architecture/0001-dispatch-architecture.md).
  Dependencies point inward toward `DispatchCore`; device, macOS, provider,
  and UI details stay outside the core. Add a Swift protocol when at least two
  implementations are useful now, usually production code and a test double.
- Follow the clean-room rule: never open or derive code from `micro-manager`
  source. Use this repository's [specifications](docs/protocol), public platform
  documentation, or observed hardware behavior. If a needed fact is missing,
  record the question rather than consulting `micro-manager`.
- For behavior changes, add tests through public interfaces. Keep
  [the runtime lifecycle model](specs/RuntimeLifecycle.tla) in step with changes
  to where `DispatchRuntime` awaits or what its tasks do; see
  [the model notes](specs/README.md).

## Build and test

Use macOS 14 or later, Xcode's Swift toolchain, SwiftLint, and Java for the TLA+
checker (`brew install openjdk`). Run the full local check before a PR:

```sh
scripts/check.sh
```

It builds, runs Swift tests, checks SwiftLint, and model-checks the TLA+ specs.
You can work without hardware: `FakePadDevice` exercises the runtime,
`RecordingMacOSAutomation` checks macOS actions, and the Herdr protocol and
socket tests use local fixture responses and fake servers. See the
[testing strategy](docs/architecture/0001-dispatch-architecture.md#testing-strategy).

Some tests are property-based: they use
[PropertyBased](https://github.com/x-sheep/swift-property-based) under Swift
Testing to check a rule against many random inputs, such as HID reassembly in
`JSONMessageAssemblerPropertyTests` and binding compilation in
`BindingCompilationPropertyTests`. A failing property prints the input, shrunk
to a small case, and a seed:

```text
Add `.fixedSeed("rZXtzXfRXju2TgyoWC5DmUdNXU5GF1yXRJSAdmytuEo=")` to the Test to reproduce this issue.
```

Add that trait, as in `@Test(.fixedSeed("…"))`, to replay exactly that case
while you fix it, then remove it so the test explores new inputs again.
PropertyBased is a test-only dependency; the app itself has none.

Changes to HID framing, firmware commands, keymaps, lighting, or physical
control mapping need a live check with a Creator Micro 2. Changes to Herdr
integration need a live Herdr check when practical. In the PR, report the
device firmware (`swift run dispatch-probe version`), Herdr version and terminal
app when relevant, what you tried, what you observed, and any live checks you
could not perform. Keep personal data and secrets out of logs.

## Troubleshooting test signing

In a File Provider-backed checkout, such as a cloud-synced `~/Documents`, a
bare `swift test` can fail while signing an `.xctest` bundle with `resource fork,
Finder information, or similar detritus not allowed`. File Provider attaches
extended attributes to build outputs. Use `scripts/check.sh`, which places
SwiftPM build products outside the checkout under
`~/Library/Caches/dispatch-build`; set `DISPATCH_BUILD_DIR` to another
non-File Provider scratch directory if needed. Do not use bare `swift test` in
these folders. Clearing attributes with `xattr -cr` or setting
`CODE_SIGNING_ALLOWED=NO` does not reliably fix the build. Put isolated
worktrees outside `~/Documents` as well.

See [the release instructions](docs/releasing.md) for tagging, bundling, and
publishing a source-built archive.
