# Contributing to Refine for Neovim

Thank you for helping improve `refine.nvim`. The plugin is a pure Lua Neovim
integration for Refine on macOS.

## Development requirements

- Neovim 0.11 or newer
- GNU Make
- [StyLua](https://github.com/JohnnyMorganz/StyLua)
- Git

The test suite does not require a running Refine app. Leave Refine stopped
unless a task explicitly requires manual integration testing.

## Repository structure

Preserve these module boundaries:

- `lua/refine/integration/` owns host-neutral lifecycle and action
  coordination.
- `lua/refine/transport/` owns the editor-neutral client for the same-UID,
  per-launch-token public Integration Protocol 1.0 connection.
- `lua/refine/nvim/` owns canonical buffer snapshots, native presentation,
  coordinate conversion, and one-mutation Apply behavior.

Keep the runtime pure Lua and compatible with Neovim 0.11 or newer. Model,
provider, policy, appearance, interaction, entitlement, and network behavior
belong to the Refine app. The plugin must not add its own network or telemetry
path.

## Protocol, support, and privacy

Integration Protocol 1.0 is a supported public API that third-party
writing-host clients may implement. Its schemas, vectors, state rules, fixed
limits, and empty base capability registry are normative. Extend the wire only
through a published capability or a successor protocol; do not silently change
the 1.0 base contract.

Refine maintains exact Protocol 1.0 compatibility throughout Refine 1.x. The
supported production profile is a conforming writing-host client connecting to
the shipping Refine server on macOS as the same local OS user, with Refine
already running. Network transports, cross-user access, sandbox workarounds,
and third-party production servers are outside that profile. Conformance is
self-assessed and does not imply certification or endorsement.

Complete canonical source snapshots cross the plugin-to-Refine boundary and
may reach the provider selected by the user. Keep plugin logs and diagnostics
free of source, diffs, explanations, launch tokens, and provider credentials.
Report must remain a distinct action caused by an explicit user gesture; its
Refine feedback-service destination and possible excerpt and context data must
stay disclosed in user-facing documentation.

## Development workflow

1. Add or update a focused test that fails for the missing behavior.
2. Implement the change through an existing public seam.
3. Run the focused test while iterating.
4. Run the full checks before submitting the change.
5. Synchronize user-visible behavior across `README.md`, `doc/refine.txt`, and
   `CHANGELOG.md` when the public interface changes.
6. Regenerate `doc/tags` after every change to `doc/refine.txt`.

Do not change transport frames, source revisions, presentation replacement,
suggestion actions, or Apply behavior without preserving the contracts in
`doc/refine.txt` and the protocol and presentation tests.

## Commands

Run the complete verification suite:

```sh
make check
```

Useful individual targets:

```sh
make format-check
make test-core
make test-nvim
make test-health
make helptags-check
```

Run every public real-socket scenario against the production transport using
the adjacent release-candidate package:

```sh
make test-conformance REFINE_PROTOCOL_ROOT=/absolute/path/to/refine-protocol
```

This gate uses the public fake Refine peer and the nonshipping
`tests/conformance/run.lua` adapter. It never launches the Refine app.

Format the Lua source and regenerate help tags when needed:

```sh
make format
make helptags
```

The Neovim test target runs every `tests/nvim/*_spec.lua` file independently.
Core transport and protocol tests live under `tests/core/`, and health checks
live under `tests/health/`.

## Protocol fixture

`tests/fixtures/refine-protocol/pin.json` identifies the content-addressed
Protocol 1.0 artifact vendored for conformance tests. Every file covered by its
manifest must remain byte-identical across consumers. Update the pin and
artifact only from one immutable upstream snapshot; never recreate shared
golden bytes in a client repository. Coordinate an intentional protocol or
capability-registry change across the Refine app and all first-party
integrations.

## Documentation

- `README.md` is the user-facing product, installation, and first-use guide.
- `docs/configuration.md` contains advanced Neovim usage, configuration, and
  troubleshooting.
- `doc/refine.txt` is the complete public interface reference available through
  `:help refine`.
- `CHANGELOG.md` records user-visible changes.

Keep examples and documented requirements accurate when public behavior
changes.

## Before submitting a change

- Confirm the change has focused test coverage.
- Run `make check`.
- Review the diff for unrelated files or generated changes.
- Confirm public documentation and help tags are synchronized.
- If manual integration testing was necessary, stop Refine afterward.
