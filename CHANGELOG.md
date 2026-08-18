# Changelog

All notable changes to Refine for Neovim will be documented here.

The project follows [Semantic Versioning](https://semver.org/). Preview
releases use `0.x`; `v1.0.0` is reserved for the first publicly supported
capability-parity release.

## [Unreleased]

### Changed

- Every suggestion card now opens focused, including the ones `:RefineNext` and
  `:RefinePrevious` open, so its card keys act without a further command. The
  caret stays on the suggestion in the owning window and closing the card
  returns focus there. A card that loses focus still shows the explicit focus
  hint for card-local keys.
- Markdown now uses the explicit `markdownDocument` source syntax, while text,
  Git commit, and mail buffers use `plainText`; this lets Refine join Markdown
  soft line breaks without changing plain-text paragraph behavior.
- The integration now requires the exact public Integration Protocol 1.0 wire
  contract; Protocol 2.5 has no compatibility alias. Version mismatches report
  both exact versions without inferring which component should update.
- The legacy `mixed` source syntax is no longer accepted in configuration or
  buffer overrides.
- A fatal `malformedMessage` engine fault now names a Refine app update instead
  of reporting only the raw fault code. That is what a plugin declaring a source
  syntax an older Refine app cannot decode looks like from Neovim.

### Added

- Pure Lua Refine integration runtime for Neovim 0.11 and newer on macOS.
- Exact Integration Protocol 1.0 transport over Refine's same-UID,
  per-launch-token local Unix socket, with support throughout Refine 1.x.
- Strict portable JSON, typed handshake recovery, capability negotiation,
  Unicode-scalar coordinate validation, and reconnect-safe Apply receipts.
- Public privacy disclosures for complete source snapshots, configured
  providers, optional redacted diagnostics, and explicit Report feedback.
- Full-buffer and selection-scoped writing checks.
- Native suggestion highlights, floating cards with inline diff runs,
  combining-glyph deletion midlines, visible changed whitespace, navigation,
  and actions.
- Alias-safe transient action keys that preserve Ctrl-I, Ctrl-[, and Ctrl-M
  when the Neovim frontend can distinguish them from Tab, Escape, and Return.
- Actionable Apply guidance, including an explicit `<Plug>(RefineApply)`
  mapping, when the configured shortcut cannot be intercepted by Neovim.
- Atomic, one-undo-entry Apply behavior.
- Optional validated setup and buffer-local overrides.
- Structured status, statusline component, and `:checkhealth refine`.
- Opt-in redacted diagnostics bounded to a 256 KiB file and one rotation.
- `"markdownDocumentHardLineBreaks"` is available wherever a source syntax is
  configured, in `setup({ filetypes = ... })` and in `configure_buffer()`. It
  protects exactly the same Markdown syntax as `"markdownDocument"` and still
  checks prose wrapped across source lines as one logical paragraph, but every
  line ending is immovable: Apply reproduces each one at the same position and
  never removes, introduces, or reflows across one. Choose it when the same
  files are rendered somewhere that shows every line ending as a line break,
  such as a default Obsidian vault; a correction that cannot keep the
  paragraph's existing line endings is dropped instead of applied. The
  `markdown` filetype default stays `"markdownDocument"`.
