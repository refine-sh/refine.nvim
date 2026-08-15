# Refine for Neovim

Refine for Neovim brings Refine's grammar and fluency suggestions into native
Neovim buffers. It connects to the Refine app on the same Mac, renders
authoritative extmark highlights and a floating suggestion card, and applies a
suggestion as one undoable buffer change.

This repository is in preview. The first capability-parity release will be
`v1.0.0`.

## Requirements

- macOS
- Neovim 0.11 or newer
- The Refine app with exact integration Protocol 2.4 support
- An active Refine trial or valid license

Refine remains the source of writing-check policy, language, model, schedule,
appearance, and interaction settings.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "runjuu/refine.nvim",
}
```

Or install it as a standard Neovim package:

```sh
git clone --filter=blob:none https://github.com/runjuu/refine.nvim \
  ~/.local/share/nvim/site/pack/refine/start/refine.nvim
nvim --headless "+helptags ALL" +qa
```

No setup call is required. Refine activates passively for eligible prose
buffers, but passive activity never launches the Refine app. `:RefineCheck`
launches Refine in the background when an explicit check needs it.

## Usage

- `:RefineCheck` checks the current eligible buffer.
- A line range, such as `:3,8RefineCheck`, checks the complete sentences
  touched by those lines.
- A Visual mapping to `<Plug>(RefineCheck)` preserves exact characterwise or
  linewise endpoints. Blockwise selections are rejected.
- `:RefineShow` opens the suggestion under the caret; invoking it again
  focuses the card.
- `:RefineNext` and `:RefinePrevious` wrap through suggestions in document
  order.
- `:RefineApply`, `:RefineDismiss`, `:RefineExplain`,
  and `:RefineReport` act on the open card first and otherwise on a suggestion
  under the caret.
- `:RefineClose` closes the card without applying or dismissing its
  suggestion.
- `:RefineStatus` explains the current state.

The plugin installs no permanent editor key mappings. Map its `<Plug>`
targets yourself. It provides `RefineCheck`, `RefineShow`, `RefineNext`,
`RefinePrevious`, `RefineApply`, `RefineDismiss`, `RefineExplain`,
`RefineReport`, and `RefineClose` targets in the form shown below:

```lua
vim.keymap.set({ "n", "x" }, "<leader>rc", "<Plug>(RefineCheck)")
vim.keymap.set("n", "<leader>rs", "<Plug>(RefineShow)")
vim.keymap.set("n", "]r", "<Plug>(RefineNext)")
vim.keymap.set("n", "[r", "<Plug>(RefinePrevious)")
```

Refine's configured Apply and Dismiss keys are intercepted only while cursor
activation or the card owns them, then the previous buffer-local mapping is
restored exactly. On cursor activation the Dismiss key cancels activation; on
an open card it explicitly dismisses the suggestion. A card claims a configured
key only while the corresponding action is live; unavailable or conflicting
keys retain their native behavior. Card ownership works from both the floating
card and its owning editor window.

The card footer and its `a`/`d`/`e`/`r` mappings include only currently
available actions. `n`, `p`, and `q` remain navigation/close controls; Escape
closes when Dismiss is unavailable. A `FileType refine` autocmd may replace the
built-in card-local mappings. Same-suggestion replacements preserve those user
overrides unless Refine's configured transient key itself changes.

When Refine temporarily owns Tab, Escape, or Return, it also preserves the
distinct Ctrl-I, Ctrl-[, or Ctrl-M mapping or native behavior. That distinction
requires a GUI or a terminal with Neovim's extended key encoding; a legacy
terminal that sends each pair identically cannot preserve it. `:checkhealth
refine` reports this limitation.

A passive key observer performs mouse hit-testing without installing or
shadowing `<LeftMouse>` mappings. A single click on a live highlight opens its
card, and available footer actions are clickable.

Apply prevalidates every expected range, composes disjoint edits inside their
smallest enclosing range, and performs one undoable buffer mutation. Extmarks
owned by other plugins inside that envelope follow Neovim's normal gravity
rules for one enclosing replacement.

## Configuration

`setup()` is optional, idempotent, validated, and atomic. Each call starts
from defaults; filetype entries merge with the default map, and `false`
removes one:

```lua
require("refine").setup({
  max_source_bytes = 1024 * 1024,
  filetypes = {
    markdown = false,
    quarto = "mixed",
  },
  frontend = "auto",
  debug_log = false,
})
```

Supported source syntaxes are `mixed` and `latexDocument`. Automatic
frontend detection recognizes Apple Terminal (`terminal`), iTerm2,
Ghostty, WezTerm, Kitty, Alacritty, and Neovide. An unknown detected frontend
uses generic behavior; an explicit override must be a recognized ID.

Setting `debug_log = true` writes redacted structured diagnostics to the path
reported by `:checkhealth refine`. Storage is bounded to a 256 KiB current
file plus one rotated file.

The default eligible filetypes are:

| Filetype | Source syntax |
| --- | --- |
| `markdown`, `text`, `gitcommit`, `mail` | `mixed` |
| `tex`, `plaintex` | `latexDocument` |

Eligibility also requires a loaded ordinary buffer that is modifiable, not
read-only or binary, and no larger than `max_source_bytes`. Buffer-list
membership is irrelevant.

Use a validated buffer-local override when needed:

```lua
require("refine").configure_buffer(0, { enabled = false })
require("refine").configure_buffer(0, {
  enabled = true,
  source_syntax = "mixed",
})
require("refine").configure_buffer(0, {}) -- inherit global configuration
```

An override never bypasses the ordinary-buffer, editability, binary, or size
safety checks.

## Status and troubleshooting

`require("refine").status(bufnr)` returns a copied semantic status table.
`require("refine").statusline(bufnr)` is a cached, side-effect-free component
for a user-owned statusline. The plugin never rewrites `'statusline'`.

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "RefineStatusChanged",
  callback = function()
    vim.cmd.redrawstatus()
  end,
})
```

Run `:checkhealth refine` to inspect Neovim and macOS support, redacted
configuration, endpoint permissions, Protocol 2.4 compatibility, frontend,
semantic state, action-key compatibility, and the debug-log path when enabled.

## Privacy and transport

The plugin talks only to the local Refine app over an authenticated,
same-user Unix-domain socket. It makes no direct network requests, telemetry,
analytics, or update checks. Plugin managers own updates. Refine may use the
local or remote provider selected in the app under Refine's existing privacy
and consent controls.

Health output and optional persistent diagnostics never include source text,
suggestion diffs, explanations, launch tokens, credentials, or other secrets.

See `:help refine` for the complete interface.

## Development

```sh
make check
make format
make helptags
```

The shared protocol transcript in `tests/fixtures/` must stay byte-identical
to the Refine app and other first-party integrations.

## License

[MIT](LICENSE)
