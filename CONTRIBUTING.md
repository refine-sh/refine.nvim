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
- `lua/refine/transport/` owns the editor-neutral authenticated Protocol 2.4
  connection.
- `lua/refine/nvim/` owns canonical buffer snapshots, native presentation,
  coordinate conversion, and one-mutation Apply behavior.

Keep the runtime pure Lua and compatible with Neovim 0.11 or newer. Model,
provider, policy, appearance, interaction, entitlement, and network behavior
belong to the Refine app. The plugin must not add its own network or telemetry
path.

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

Format the Lua source and regenerate help tags when needed:

```sh
make format
make helptags
```

The Neovim test target runs every `tests/nvim/*_spec.lua` file independently.
Core transport and protocol tests live under `tests/core/`, and health checks
live under `tests/health/`.

## Protocol fixture

`tests/fixtures/integration-protocol-v2.json` is shared across first-party
Refine integrations. It must remain byte-identical in every client. Coordinate
any intentional protocol change across the Refine app and all first-party
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
