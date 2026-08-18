# Advanced usage and configuration

`refine.nvim` works without a `setup()` call. Refine owns model selection,
providers, languages, checking schedules, prompts, appearance, action keys,
privacy controls, and licensing. Configure those choices in the Refine app.

Use this document when you need to change which Neovim buffers are eligible,
integrate Refine into your mappings or statusline, override frontend
detection, or collect redacted diagnostics.

For the complete public contract, including lifecycle details, read
`:help refine` or [`doc/refine.txt`](../doc/refine.txt).

## Setup

`setup()` replaces the global plugin configuration. It is optional,
idempotent, validated, and atomic. Every call starts from the defaults, so a
later call does not merge with an earlier call. Invalid input raises an error
and leaves the live configuration unchanged.

```lua
require("refine").setup({
  max_source_bytes = 1024 * 1024,
  filetypes = {
    markdown = false,
    quarto = "markdownDocument",
  },
  frontend = "auto",
  debug_log = false,
})
```

| Option | Default | Description |
| --- | --- | --- |
| `max_source_bytes` | `1024 * 1024` | Maximum UTF-8 byte length of one captured buffer. Must be a positive integer. |
| `filetypes` | See [Filetypes](#filetypes) | Adds, replaces, or removes entries in the default filetype map. |
| `frontend` | `"auto"` | Detect the Neovim frontend automatically or use a recognized frontend ID. |
| `debug_log` | `false` | Write bounded, redacted diagnostic metadata for troubleshooting. |

Unknown options and invalid values are rejected.

## Filetypes

Refine supports four source syntaxes:

- `"plainText"` for prose whose physical line breaks are paragraph boundaries
- `"markdownDocument"` for Markdown, including soft line breaks within logical paragraphs
- `"markdownDocumentHardLineBreaks"` for Markdown whose every line ending is a
  visible line break, so Refine never moves one
- `"latexDocument"` for TeX and LaTeX documents

`"markdownDocumentHardLineBreaks"` protects exactly the same Markdown syntax as
`"markdownDocument"`, and prose wrapped across source lines is still checked as
one logical paragraph. The difference is Apply: every line ending is immovable,
reproduced at the same position, and Refine never removes, introduces, or
reflows across one. The trade-off is that a correction which cannot keep the
paragraph's existing line endings is dropped instead of applied.

The default map is:

| Neovim filetype | Source syntax |
| --- | --- |
| `markdown` | `markdownDocument` |
| `text` | `plainText` |
| `gitcommit` | `plainText` |
| `mail` | `plainText` |
| `tex` | `latexDocument` |
| `plaintex` | `latexDocument` |

Entries passed to `filetypes` merge with that default map. Set an entry to
`false` to remove it:

```lua
require("refine").setup({
  filetypes = {
    markdown = false,
    quarto = "markdownDocument",
    context = "latexDocument",
  },
})
```

### Obsidian vaults and other hard-line-break Markdown

`markdown` stays mapped to `"markdownDocument"`. Neovim Markdown buffers are
commonly hard-wrapped at `'textwidth'`, where reflow inside one logical
paragraph is invisible in the rendered output.

Opt in to `"markdownDocumentHardLineBreaks"` when the same files are rendered
somewhere that shows every line ending as a line break, such as a default
Obsidian vault. Map the filetype globally:

```lua
require("refine").setup({
  filetypes = {
    markdown = "markdownDocumentHardLineBreaks",
  },
})
```

To keep the global default and opt in for one vault only, scope a buffer
override by path:

```lua
local vault = vim.fn.expand("~/Documents/Vault")

vim.api.nvim_create_autocmd("BufReadPost", {
  pattern = vault .. "/*.md",
  callback = function(args)
    require("refine").configure_buffer(args.buf, {
      source_syntax = "markdownDocumentHardLineBreaks",
    })
  end,
})
```

## Buffer eligibility

An eligible buffer must be:

- valid and loaded
- an ordinary buffer with an empty `'buftype'`
- modifiable and neither read-only nor binary
- valid UTF-8
- no larger than `max_source_bytes`
- mapped to a supported source syntax

Whether the buffer appears in the buffer list does not matter. An override can
opt a filetype in or out, but it cannot bypass the ordinary-buffer,
editability, binary, UTF-8, or size checks.

Refine captures the exact buffer lines joined with LF and does not invent a
terminal newline. Applying a suggestion does not change `'fileformat'`,
`'endofline'`, or `'fixendofline'`.

## Buffer-local overrides

`configure_buffer()` replaces the override for one buffer atomically. Pass
zero for the current buffer. An empty table clears the override and returns to
the global configuration.

```lua
require("refine").configure_buffer(0, { enabled = false })

require("refine").configure_buffer(0, {
  enabled = true,
  source_syntax = "markdownDocument",
})

require("refine").configure_buffer(0, {})
```

Supported fields:

| Field | Description |
| --- | --- |
| `enabled` | `false` opts out. `true` permits normal eligibility evaluation. |
| `source_syntax` | `"plainText"`, `"markdownDocument"`, `"markdownDocumentHardLineBreaks"`, or `"latexDocument"`. This can opt an otherwise unmapped filetype in. |

## Automatic and manual checks

Automatic Checks are controlled by Refine and enabled by default. When Refine
is running, entering or editing an eligible buffer lets the app schedule a
check according to its settings. Passive Neovim activity never launches the
app.

Use `:RefineCheck` for an explicit check. It launches Refine in the background
when needed without taking focus.

- With no range, `:RefineCheck` checks the full buffer.
- An Ex line range checks the complete sentences touched by those lines.
- A Visual `<Plug>(RefineCheck)` mapping preserves exact characterwise or
  linewise endpoints.
- Blockwise Visual selections are rejected.

## Commands

| Command | Behavior |
| --- | --- |
| `:[range]RefineCheck` | Request a fresh manual writing check for the buffer or selection. |
| `:RefineShow` | Open and focus the suggestion under the cursor, or focus its open preview. |
| `:RefineNext` | Move to the next suggestion, then open and focus its card. Navigation wraps. |
| `:RefinePrevious` | Move to the previous suggestion, then open and focus its card. Navigation wraps. |
| `:RefineApply` | Apply the open suggestion, or the suggestion under the cursor. |
| `:RefineDismiss` | Dismiss the open suggestion, or the suggestion under the cursor. |
| `:RefineExplain` | Stream an explanation when that action is available. |
| `:RefineReport` | Report the current suggestion when feedback is available. |
| `:RefineClose` | Close the card without applying or dismissing its suggestion. |
| `:RefineStatus` | Display the semantic state for the current source buffer. |

Explicit command failures notify with an actionable message. Passive
connection and background transitions update status silently. An Apply with
an indeterminate outcome is never retried automatically.

## Mappings

The plugin installs no permanent mappings. It provides these targets:

| Target | Modes |
| --- | --- |
| `<Plug>(RefineCheck)` | Normal and Visual |
| `<Plug>(RefineShow)` | Normal |
| `<Plug>(RefineNext)` | Normal |
| `<Plug>(RefinePrevious)` | Normal |
| `<Plug>(RefineApply)` | Normal |
| `<Plug>(RefineDismiss)` | Normal |
| `<Plug>(RefineExplain)` | Normal |
| `<Plug>(RefineReport)` | Normal |
| `<Plug>(RefineClose)` | Normal |

Example:

```lua
vim.keymap.set({ "n", "x" }, "<leader>rc", "<Plug>(RefineCheck)")
vim.keymap.set("n", "<leader>rs", "<Plug>(RefineShow)")
vim.keymap.set("n", "]r", "<Plug>(RefineNext)")
vim.keymap.set("n", "[r", "<Plug>(RefinePrevious)")
vim.keymap.set("n", "<leader>ra", "<Plug>(RefineApply)")
vim.keymap.set("n", "<leader>rd", "<Plug>(RefineDismiss)")
vim.keymap.set("n", "<leader>re", "<Plug>(RefineExplain)")
vim.keymap.set("n", "<leader>rr", "<Plug>(RefineReport)")
vim.keymap.set("n", "<leader>rq", "<Plug>(RefineClose)")
```

### Transient Refine action keys

Refine's configured Apply and Dismiss keys are intercepted only while cursor
activation or an open card owns them. Previous buffer-local mappings are
restored exactly afterward. A key is claimed only while its action is
available, so conflicting or unavailable actions retain their native behavior.

When the configured Apply key cannot be intercepted, the activation tip says
`Apply shortcut unavailable`. The card explains how to configure another Apply
key in Refine or add a `<Plug>(RefineApply)` mapping such as `<leader>ra` from
the example above. Refine does not remap the key automatically.

When Refine temporarily owns Tab, Escape, or Return, it also preserves the
distinct Ctrl-I, Ctrl-[, or Ctrl-M behavior. This distinction requires a GUI
or terminal with Neovim's extended key encoding. A legacy terminal may send
each pair identically. `:checkhealth refine` reports that limitation.

## Suggestion card

`:RefineShow`, `:RefineNext`, `:RefinePrevious`, and a source-highlight click
all open and focus the card immediately, so its card keys act without a further
command. The cursor stays on the suggestion in the owning window, and closing
the card returns focus there. A card that loses focus, after switching windows
for example, displays `Preview · :RefineShow to focus for card keys`; one
`:RefineShow` focuses it again. Moving away, changing the source, switching its
owning window, or superseding its suggestion closes it.

Diff runs follow their natural text flow inside the card, so word replacements
appear inline and long text wraps normally. Additions are bold in the configured
addition color; deletions use the configured deletion color and a combining-glyph
midline fallback when terminals do not render native strikethrough. Changed
whitespace uses visible markers when that appearance option is enabled.

The action mappings and footer entries are available only when their action is
live:

| Key | Action |
| --- | --- |
| `a` | Apply |
| `d` | Dismiss |
| `e` | Explain |
| `r` | Report |

These controls remain available independently of suggestion actions:

| Key | Action |
| --- | --- |
| `n` | Next suggestion |
| `p` | Previous suggestion |
| `q` | Close |
| `Esc` | Close unless Escape is currently owned as Refine's configured Dismiss key |

Replace these buffer-local mappings with a `FileType refine` autocmd when you
want different card controls. Same-suggestion replacements preserve your
overrides unless the relevant Refine-configured transient key changes.

A plain left click on a live highlight opens and focuses its card. Refine
observes clicks without installing or shadowing a `<LeftMouse>` mapping.
Available footer actions are clickable.

## Apply behavior

Apply validates the expected source, composes disjoint edits inside their
smallest enclosing range, and performs one buffer mutation with one undo
entry. Extmarks owned by other plugins inside that envelope follow Neovim's
normal gravity rules for one enclosing replacement.

If the source no longer matches the suggestion, Refine rejects the Apply
instead of editing stale text.

## Frontend detection

The default `frontend = "auto"` recognizes:

- Apple Terminal
- iTerm2
- Ghostty
- WezTerm
- Kitty
- Alacritty
- Neovide

The corresponding explicit IDs are `"terminal"`, `"iterm2"`, `"ghostty"`,
`"wezterm"`, `"kitty"`, `"alacritty"`, and `"neovide"`. An unknown
automatically detected frontend uses generic behavior. An explicit override
must use a recognized ID.

The plugin is inactive in headless Neovim and activates when a UI attaches.
SSH is supported when Neovim runs on macOS and can reach the same-machine
Refine endpoint. If several distinct UIs are attached, the plugin omits
frontend identity instead of guessing.

## Status and statusline integration

```lua
local status = require("refine").status(bufnr)
local component = require("refine").statusline(bufnr)
```

`status()` returns a copy of the semantic state. Use it for programmatic
logic. `statusline()` returns a cached, side-effect-free string for a
user-owned statusline. The plugin never rewrites `'statusline'`.

Call `statusline()` from your existing statusline component. Refine requests a
statusline redraw and emits the `RefineStatusChanged` User event whenever its
semantic state changes. Event data contains the affected buffer number.

### Custom wording and icons

`statusline()` text is presentation and may change between releases. Build your
own component from `status()` instead, which is a stable interface:

```lua
local function refine_component()
  local status = require("refine").status()
  if status.state == "checking" then
    local progress = status.progress
    return progress and ("󰗧 %d/%d"):format(progress.completed, progress.total)
      or "󰗧 checking"
  elseif status.state == "complete" then
    return ("󰗧 %d"):format(status.suggestion_count or 0)
  elseif status.state == "connecting" then
    return "󰗧 …"
  elseif status.state == "unavailable" then
    return "󰗧 !"
  end
  return ""
end
```

Keep the final fallback. Minor releases may add states, reasons, and warning
codes, and callers must tolerate unknown values.

Refine already calls `redrawstatus()` on every status change, so a component
like this needs no autocommand. Listen for `RefineStatusChanged` only to drive
something else, such as a spinner timer or a notification:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "RefineStatusChanged",
  callback = function(args)
    local bufnr = args.data.bufnr
    -- react to the new state for bufnr
  end,
})
```

### When the component stays empty

`statusline()` returns an empty string for any buffer without an active
session, so a scratch buffer or an unsupported filetype shows nothing at all.
Ask Refine what it thinks the current buffer is doing:

```vim
:lua =vim.inspect(require("refine").status())
```

`status()` always returns a table. When `state` is `inactive`, the `reason`
field explains why:

| `reason` | Meaning |
| --- | --- |
| `unsupported_filetype` | The buffer's filetype is not in the configured map. |
| `not_active_buffer` | Another buffer holds the live session. |
| `no_ui` | No UI is attached. The plugin is inactive in headless Neovim. |
| `unsupported_platform` | The host is not macOS. |
| `disconnected` | Not connected to the Refine app. |
| `incompatible_protocol` | The plugin and app protocol versions do not match. |

A buffer with no filetype is the most common cause. Save the file with a `.md`
extension or set the filetype explicitly, then check again.

Note that `:lua =` prints a result while plain `:lua` does not. Running
`:lua require("refine").statusline()` evaluates the call and discards the
result, which looks like nothing happened.

Run `:checkhealth refine` for the full report.

## Diagnostics and health

Run:

```vim
:checkhealth refine
```

The report covers:

- Neovim version and macOS platform
- redacted configuration
- same-user endpoint permissions
- exact local and remote Integration Protocol 1.0 versions
- detected or generic frontend state
- semantic integration state
- configured action-key compatibility
- terminal key-alias limitations
- the debug-log path and retention when logging is enabled

Enable persistent diagnostic metadata only while troubleshooting:

```lua
require("refine").setup({
  debug_log = true,
})
```

The log path appears in `:checkhealth refine`. Storage is bounded to a 256 KiB
current file plus one rotated file. Health output and persistent diagnostics
never include source text, suggestion diffs, explanations, launch tokens,
credentials, or other secrets.

## Privacy, protocol, and support

The plugin talks only to the local Refine app over a same-UID Unix-domain socket
using Refine's current per-launch token. This excludes network clients and other
OS users, but does not identify a specific plugin or protect against another
process already running as you. The plugin makes no direct network, telemetry,
analytics, or update-check requests. Plugin managers own plugin updates.

The plugin sends complete canonical source snapshots to Refine. Refine may use
the local model or a remote provider selected in the app under its privacy and
consent controls; that provider may therefore receive the source. See
[Local AI and privacy](../README.md#local-ai-and-privacy) for the user-facing
summary.

`:RefineReport` is distinct from writing checks and sends feedback through the
Refine app only after you invoke it. Refine's feedback service may receive
original and revised excerpts plus suggestion, model, language,
custom-instruction, Refine-version, and macOS-version context. The
[Refine privacy policy](https://refine.sh/privacy-policy) describes that
processing.

Integration Protocol 1.0 is a supported public API that third-party
writing-host clients may implement. This plugin requires exact Protocol 1.0;
there is no Protocol 2.5 alias. Refine maintains exact 1.0 compatibility
throughout Refine 1.x.

The supported production profile connects a conforming writing-host client to
the shipping Refine server on macOS as the same local OS user, with Refine
already running. Network transports, cross-user access, and third-party
production servers are outside that profile. Technical conformance is
self-assessed and does not imply certification or endorsement.

A mismatch fails before source is sent and reports the exact local and remote
versions. It does not infer an update direction from their numeric ordering;
install a compatible Refine app and plugin pair, then reconnect.
