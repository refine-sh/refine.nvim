# Refine for Neovim Contributor Guidance

Keep the public interface in `doc/refine.txt`, `README.md`, and
`CHANGELOG.md` synchronized. Regenerate `doc/tags` after help changes.

Before changing transport frames, source revisions, presentation replacement,
suggestion actions, or Apply behavior, preserve the public interface documented
in `doc/refine.txt` and exercised by the protocol and presentation contract
tests.

Preserve these module seams:

- `lua/refine/integration/` owns host-neutral lifecycle and action
  coordination.
- `lua/refine/transport/` owns the editor-neutral client for the same-UID,
  per-launch-token public Integration Protocol 1.0 connection.
- `lua/refine/nvim/` owns canonical buffer snapshots, native presentation,
  coordinate conversion, and one-mutation Apply.

Keep the runtime pure Lua on Neovim 0.11 or newer. Preserve the shared protocol
fixture byte-for-byte across first-party clients. Route all model, provider,
policy, appearance, interaction, entitlement, and network behavior through the
Refine app; the plugin owns no direct network or telemetry path.

Use `apply_patch` for edits. Add behavior through a public seam with a red test
first, then run `make check`. Leave the app stopped unless a task explicitly
requires manual integration validation. For protocol-contract changes, also
run `make test-conformance REFINE_PROTOCOL_ROOT=/absolute/path/to/refine-protocol`;
that gate uses a fake peer and does not launch the app.
