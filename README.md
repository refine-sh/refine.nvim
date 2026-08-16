<div align="center">
  <a href="https://refine.sh">
    <img src="https://refine.sh/icon.png" width="128" alt="Refine icon">
  </a>
  <h1>Refine.nvim</h1>
  <p><strong>A native AI grammar checker and writing assistant for Neovim, powered by Refine.</strong></p>
  <p>
    <a href="https://refine.sh"><img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or newer"></a>
    <a href="https://neovim.io"><img src="https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.11 or newer"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  </p>
</div>

Refine for Neovim is an AI grammar checker and writing assistant for Markdown,
Git commit messages, email, plain text, and LaTeX. Use Refine's built-in local
models for private, on-device checks that keep working offline after download,
or connect your own AI provider.

Review each suggestion through native Neovim highlights and floating cards,
ask for an explanation, and apply the correction as one undoable edit.
Card diffs keep word replacements inline: additions are bold, deletions carry
a visible midline, and changed whitespace is marked when enabled.

[Refine](https://refine.sh) supplies the models, languages, checking policy,
and writing settings. `refine.nvim` supplies the native editor experience. The
plugin requires the Refine app for macOS and is not a standalone checker.

<!--
Demo: add assets/refine-nvim-demo.gif, then replace this comment with:

![Refine checking Markdown grammar with local AI in Neovim](assets/refine-nvim-demo.gif)
-->

## Why use Refine in Neovim?

- **Write with local AI.** A downloaded Refine model runs on your Mac, keeps
  check text on your device, and works without an internet connection.
- **Stay inside Neovim.** Suggestions appear as native highlights with a
  focused card for reviewing the diff and available actions.
- **Check the right scope.** Refine can check an entire buffer, the sentences
  touched by a line range, or an exact Visual selection.
- **Work across languages.** Refine supports grammar and fluency checks in more
  than 50 languages and regional variants.
- **Understand each correction.** Review suggestions individually, ask why a
  change was proposed, and decide whether to apply, dismiss, or report it.
- **Keep edits predictable.** Applying a suggestion performs one validated
  buffer mutation and creates one undo entry.

There is no language server, Java runtime, model endpoint, or provider API key
to configure in Neovim. Those choices live in Refine.

## Requirements

- macOS 14 or newer
- Neovim 0.11 or newer
- A compatible Refine for Mac
- An active Refine trial or license

Refine includes a full-featured seven-day trial with no credit card required.

## Quick start

### 1. Install and set up Refine

Install Refine with Homebrew:

```sh
brew install --cask refine
```

You can also [download Refine for Mac](https://refine.sh) directly. Launch the
app, start the trial or activate your license, and download a local model if
you want on-device and offline checks.

### 2. Install `refine.nvim`

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "runjuu/refine.nvim",
}
```

No `setup()` call is required.

#### Without a plugin manager

Clone the plugin into Neovim's native package directory:

```sh
mkdir -p ~/.local/share/nvim/site/pack/refine/start
git clone --filter=blob:none https://github.com/runjuu/refine.nvim \
  ~/.local/share/nvim/site/pack/refine/start/refine.nvim
```

### 3. Start writing

Restart Neovim if it was already open, then open a supported prose buffer while
Refine is running. Automatic Checks are enabled by default, so suggestions
appear after you pause while editing.

Use `:RefineCheck` whenever you want an immediate manual check. An explicit
check can launch Refine in the background without stealing focus. Passive
buffer activity never launches the app.

## Recommended mappings

The plugin installs no permanent key mappings. These mappings cover the common
review workflow:

```lua
vim.keymap.set({ "n", "x" }, "<leader>rc", "<Plug>(RefineCheck)")
vim.keymap.set("n", "<leader>rs", "<Plug>(RefineShow)")
vim.keymap.set("n", "]r", "<Plug>(RefineNext)")
vim.keymap.set("n", "[r", "<Plug>(RefinePrevious)")
vim.keymap.set("n", "<leader>ra", "<Plug>(RefineApply)")
```

When the configured Apply key cannot be intercepted by Neovim, the activation
tip says `Apply shortcut unavailable`. The card explains how to configure
another Apply key in Refine or add the Neovim mapping above. Refine does not
remap the key automatically.

The Check mapping supports Normal and Visual mode. Characterwise and linewise
Visual selections preserve their exact endpoints. Blockwise selections are
not supported.

See [Advanced configuration](docs/configuration.md#mappings) for every
available `<Plug>` target and card mapping.

## Commands

| Command | Action |
| --- | --- |
| `:[range]RefineCheck` | Check the buffer or the complete sentences touched by a line range. |
| `:RefineShow` | Open the suggestion under the cursor, or focus its open card. |
| `:RefineNext` / `:RefinePrevious` | Move through suggestions in document order. Navigation wraps. |
| `:RefineApply` | Apply the open suggestion, or the suggestion under the cursor. |
| `:RefineDismiss` | Dismiss the open suggestion, or the suggestion under the cursor. |
| `:RefineExplain` | Request an explanation for the current suggestion. |
| `:RefineReport` | Send feedback about the current suggestion when available. |
| `:RefineClose` | Close the card without applying or dismissing the suggestion. |
| `:RefineStatus` | Show the current integration state. |

## Supported writing formats

Markdown, plain text, Git commit messages, email, TeX, and LaTeX are enabled by
default. You can add another Neovim filetype or disable a default through
[advanced configuration](docs/configuration.md#filetypes).

Only ordinary, editable, valid UTF-8 buffers within the configured size limit
are eligible. Refine never changes file format or end-of-line settings.

## Local AI and privacy

When a writing task uses a downloaded Refine local model, the check text and
model response stay on your Mac. The model can keep checking offline after it
has been downloaded.

Refine can also use a provider you connect. Those requests go directly from
your Mac to that provider, whose terms and privacy practices apply. Downloads,
updates, standard license services, and hosted providers still require an
internet connection.

The Neovim plugin connects only to the local Refine app through an
authenticated, same-user Unix socket. It makes no direct network, telemetry,
analytics, or update-check requests.

`:RefineReport` is explicit, opt-in feedback. When you use it, Refine receives
the relevant before-and-after excerpt plus suggestion and diagnostic metadata.

Read [How Refine works](https://refine.sh/guides/how-refine-works), the
[offline grammar checker guide](https://refine.sh/guides/offline-grammar-checker-mac),
and the [privacy policy](https://refine.sh/privacy-policy) for the complete
product boundaries.

## Troubleshooting

Run the built-in health check:

```vim
:checkhealth refine
```

It checks the Neovim version and macOS platform, plugin configuration, local
endpoint permissions, protocol compatibility, frontend detection, action-key
support, integration state, and the optional debug-log path.

`:RefineStatus` provides a shorter view of the current buffer state. If no
suggestions appear, first confirm that Refine is running, Automatic Checks are
enabled, and the current filetype is supported.

## Documentation

- [Advanced configuration](docs/configuration.md) covers filetypes, buffer
  overrides, mappings, statusline integration, frontend detection, and
  diagnostics.
- [`:help refine`](doc/refine.txt) is the complete public interface reference.
- [Contributing](CONTRIBUTING.md) covers development setup, tests, module
  boundaries, and documentation synchronization.
- [Changelog](CHANGELOG.md) records user-visible changes.

## License

[MIT](LICENSE)
