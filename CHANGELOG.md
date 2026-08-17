# Changelog

All notable changes to Refine for Neovim will be documented here.

The project follows [Semantic Versioning](https://semver.org/). Preview
releases use `0.x`; `v1.0.0` is reserved for the first publicly supported
capability-parity release.

## [Unreleased]

### Changed

- `:RefineShow` and source-highlight clicks now focus a suggestion card
  immediately; navigation retains unfocused previews with an explicit focus
  hint for card-local keys.
- Markdown now uses the explicit `markdownDocument` source syntax, while text,
  Git commit, and mail buffers use `plainText`; this lets Refine join Markdown
  soft line breaks without changing plain-text paragraph behavior.
- The integration now requires the exact public Integration Protocol 1.0 wire
  contract; Protocol 2.5 has no compatibility alias. Version mismatches report
  both exact versions without inferring which component should update.
- The legacy `mixed` source syntax is no longer accepted in configuration or
  buffer overrides.

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
