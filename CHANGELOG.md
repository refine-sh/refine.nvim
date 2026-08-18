# Changelog

All notable changes to Refine for Neovim will be documented here.

The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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

### Changed

- The suggestion card now draws as a bordered panel whose title names the
  suggestion kind, over a background one shade off `Normal`, with a border
  blended from the `Normal` foreground, bold title and footer action keys, and
  dimmed attribution and preview hint. Cards used to inherit the floating-window
  background, which several color schemes—including Neovim's default—leave close
  enough to the editor background that a card read as buffer text. Chrome is the
  same for every card and comes from the color scheme, so grammar and fluency
  stay a source-highlight distinction in the configured colors. The border
  counts against the room a card may take, so the whole panel still fits inside
  80% of its window's width and half its height.
- A fatal `malformedMessage` engine fault now names a Refine app update instead
  of reporting only the raw fault code. That is what a plugin declaring a source
  syntax an older Refine app cannot decode looks like from Neovim.
- The suggestion card now draws as a bordered panel whose title names the
  suggestion kind, over a background one shade off `Normal`, with a border
  blended from the `Normal` foreground, bold title and footer action keys, and
  dimmed attribution and preview hint. Cards used to inherit the floating-window
  background, which several color schemes—including Neovim's default—leave close
  enough to the editor background that a card read as buffer text. Chrome is the
  same for every card and comes from the color scheme, so grammar and fluency
  stay a source-highlight distinction in the configured colors. The border
  counts against the room a card may take, so the whole panel still fits inside
  80% of its window's width and half its height.

## [1.0.0] - 2026-08-17

First public release. Refine for Neovim presents the Refine grammar checker's
contextual writing suggestions in native Neovim buffers, so prose gets the same
review as code without leaving the editor. Checks can run entirely on your Mac
against a local language model.

Requires macOS 14 or newer, Neovim 0.11 or newer, and Refine 1.35 or newer.

### Checking your writing

- Suggestions arrive as you pause while editing, when Automatic Checks are
  enabled in Refine.
- `:RefineCheck` runs an immediate check, and launches Refine in the background
  when it is not already running, without stealing focus. Passive buffer
  activity never launches the app.
- `:[range]RefineCheck` and the Visual-mode mapping check a selection instead of
  the whole buffer. Characterwise and linewise selections keep their exact
  endpoints and expand to the complete sentences they touch.
- Markdown, plain text, Git commit messages, email, TeX, and LaTeX are enabled
  by default. Markdown is checked as Markdown, so soft line breaks are joined
  rather than treated as sentence ends.
- Only ordinary, editable, valid UTF-8 buffers within the configured size limit
  are checked. Refine never changes a file's format or end-of-line settings.

### Reviewing suggestions

- Suggestions appear as native highlights in the buffer, with a floating card
  showing the proposed change as an inline diff.
- Every card opens focused, so `a`, `d`, `e`, `r`, and `q` act immediately. The
  cursor stays on the suggestion, and closing the card returns focus to it.
- `:RefineNext` and `:RefinePrevious` move between suggestions and wrap at the
  ends. `:RefineShow` opens the suggestion under the cursor, and a plain mouse
  click on an underlined suggestion does the same.
- `:RefineExplain` requests an explanation of why a change was suggested, and
  the card grows as the explanation streams in.
- Deletions of combining glyphs get a visible midline, and changed whitespace is
  shown rather than left invisible.

### Applying changes

- `:RefineApply` applies the open suggestion, or the one under the cursor, as a
  single atomic edit that undoes in one step.
- `:RefineDismiss` dismisses a suggestion, and `:RefineClose` closes a card
  without applying or dismissing.
- When Refine's configured Quick Apply key cannot be intercepted by Neovim, the
  card says so and explains how to choose another key in Refine or map
  `<Plug>(RefineApply)`. The key is never silently remapped.
- Card keys preserve `Ctrl-I`, `Ctrl-[`, and `Ctrl-M` as distinct from `Tab`,
  `Esc`, and `Return` on frontends that can tell them apart.

### Configuration

- Works with no configuration. `setup()` is optional.
- `require("refine").setup()` replaces configuration atomically and validates
  every option. An invalid option raises an error and leaves the previous
  working configuration in place.
- `require("refine").configure_buffer()` overrides filetype handling for a
  single buffer.
- No permanent key mappings are installed. Every action is available as a
  `<Plug>` target to map as you prefer.
- `require("refine").statusline()` returns a ready-to-use statusline component,
  `refine.status()` returns machine-readable state, and the
  `RefineStatusChanged` User autocommand fires when that state changes.

### Status and troubleshooting

- `:checkhealth refine` reports Neovim version and platform, configuration,
  endpoint permissions, protocol compatibility, frontend detection, action-key
  support, integration state, and the debug-log path.
- `:RefineStatus` gives a short view of the current buffer's state.
- A protocol mismatch between plugin and app stops before any source is sent and
  reports both exact versions, without guessing which side should update.
- Interrupted connections reconnect without applying a suggestion twice.
- Optional debug logging is off by default. When enabled it records only
  bounded, redacted metadata, capped at 256 KiB with a single rotation.

### Privacy

- The plugin sends a complete snapshot of each eligible buffer to the local
  Refine app. With a downloaded local model, that source and the response stay
  on your Mac and keep working offline.
- If you connect an external provider in Refine, those requests go from your Mac
  to that provider and may include your source, under that provider's terms.
- The plugin connects only to the local Refine app over a same-UID Unix-domain
  socket using a per-launch token. It makes no network, telemetry, analytics, or
  update-check requests of its own.
- Debug logs never contain source, diffs, explanations, launch tokens, or
  provider credentials.
- `:RefineReport` is explicit feedback: only when you invoke it may Refine send
  excerpts and suggestion context to its feedback service.
