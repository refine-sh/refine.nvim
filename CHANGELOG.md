# Changelog

All notable changes to Refine for Neovim will be documented here.

The project follows [Semantic Versioning](https://semver.org/). Preview
releases use `0.x`; `v1.0.0` is reserved for the first publicly supported
capability-parity release.

## [Unreleased]

### Changed

- `:RefineShow` now focuses a suggestion card on its first invocation;
  navigation and highlight clicks retain unfocused previews with an explicit
  focus hint for card-local keys.

### Added

- Pure Lua Refine integration runtime for Neovim 0.11 and newer on macOS.
- Exact Protocol 2.4 transport over Refine's authenticated local Unix socket.
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
