# Dispatch contributor instructions

Dispatch is a clean implementation inspired by [`micro-manager`](https://github.com/schacon/micro-manager).
That project has no open source license, so its code cannot be reused here. Do
not open or derive an implementation from its source files. Implement from this repository's
architecture and protocol specifications, from public platform documentation,
or from observations of hardware and external services. If a required fact is
missing, stop and record the question instead of consulting `micro-manager`.

Keep dependencies pointing inward toward `DispatchCore`. Hardware, macOS,
provider, and UI details must not enter the core model. The Creator Micro
driver emits device-independent events and never interprets a user's binding.
External adapters execute actions and never receive physical controls or user
configuration.

Add a Swift protocol only when at least two implementations are useful now,
normally a production implementation and a test double. Do not introduce a
protocol for every operation. Keep integration-specific actions specific; do
not generalize a Herdr operation until another implementation shares the same
semantics.

Split files and types only along real conceptual boundaries. Never split,
compress, or strip comments from code just to satisfy a SwiftLint length
limit; if a length limit seems to force a bad split, raise it with the user
instead.

All behavior changes require tests through a public interface. Tests must not
assert against implementation source text. Run validation with
`scripts/check.sh` (which runs `swift build`, `swift test --parallel`,
`swiftlint --strict`, and the TLA+ model checker) before committing. Do not run a bare `swift test` in
this repository: `~/Documents` is File Provider-backed, and extended
attributes that macOS attaches to build outputs inside the repo break the
codesigning of test bundles. The script builds in a scratch path outside the
repository (`DISPATCH_BUILD_DIR`, defaulting to `~/Library/Caches/dispatch-build`)
to avoid this.

`specs/RuntimeLifecycle.tla` models `DispatchRuntime`'s lifecycle. When you
change where `DispatchRuntime` awaits, or what its tasks do, update the spec
to match. See `specs/README.md`. The checker needs Java
(`brew install openjdk`).
