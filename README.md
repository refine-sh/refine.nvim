<div align="center">
  <a href="https://refine.sh?utm_source=refine.nvim&utm_medium=readme">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://refine.sh/icon-dark.png">
      <img src="https://refine.sh/icon.png" width="128" alt="Refine icon">
    </picture>
  </a>
  <h1>Refine.nvim</h1>
  <p><strong>A local-first AI grammar checker and writing assistant for Neovim, powered by <a href="https://refine.sh?utm_source=refine.nvim&utm_medium=readme">Refine</a>.</strong></p>
  <p>
    <a href="https://refine.sh?utm_source=refine.nvim&utm_medium=readme"><img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or newer"></a>
    <a href="https://neovim.io"><img src="https://img.shields.io/badge/Neovim-0.11%2B-57A143?logo=neovim&logoColor=white" alt="Neovim 0.11 or newer"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  </p>
</div>

Refine is an AI grammar checker powered by a local language model, so it can run
entirely offline. This plugin brings its contextual grammar and fluency
suggestions to Neovim, helping you improve your writing without leaving your
editor.

Features:

- Private, offline checks powered by a local LLM on your device
- Native highlights and floating cards for reviewing changes in context
- Clear explanations of why each change is suggested

<!--
![Refine checking Markdown grammar with local AI in Neovim](assets/refine-nvim-demo.gif)
-->

## Requirements

- macOS 14+
- Neovim 0.11+
- Refine 1.35+

Refine includes a full-featured seven-day trial with no credit card required.

## Quick start

### 1. Install and set up Refine

Install Refine with Homebrew:

```sh
brew install --cask refine
```

You can also [download Refine for Mac](https://refine.sh?utm_source=refine.nvim&utm_medium=readme)
directly.

### 2. Install `refine.nvim`

Choose one of the following installation methods. No `setup()` call is
required.

#### Option 1: With lazy.nvim

Add `refine.nvim` to your [lazy.nvim](https://github.com/folke/lazy.nvim)
plugin spec:

```lua
{
  "runjuu/refine.nvim",
}
```

#### Option 2: Without a plugin manager

Alternatively, clone the plugin into Neovim's native package directory:

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
| `:RefineShow` | Open and focus the suggestion under the cursor, or focus its open preview. |
| `:RefineNext` / `:RefinePrevious` | Move through suggestions and open an unfocused preview. Navigation wraps. |
| `:RefineApply` | Apply the open suggestion, or the suggestion under the cursor. |
| `:RefineDismiss` | Dismiss the open suggestion, or the suggestion under the cursor. |
| `:RefineExplain` | Request an explanation for the current suggestion. |
| `:RefineReport` | Send feedback about the current suggestion when available. |
| `:RefineClose` | Close the card without applying or dismissing the suggestion. |
| `:RefineStatus` | Show the current integration state. |

A plain click on an underlined suggestion also opens and focuses its card.
Next and Previous previews keep editor focus.

## Supported writing formats

Markdown, plain text, Git commit messages, email, TeX, and LaTeX are enabled by
default. You can add another Neovim filetype or disable a default through
[advanced configuration](docs/configuration.md#filetypes).

Only ordinary, editable, valid UTF-8 buffers within the configured size limit
are eligible. Refine never changes file format or end-of-line settings.

## Local AI and privacy

The plugin sends a complete canonical snapshot of each eligible buffer to the
local Refine app. When Refine uses a downloaded local model, that source and
the model response stay on your Mac. Once downloaded, the model continues
working offline.

Refine can also use a provider you connect. Those requests go directly from
your Mac to that provider and may include the source, so that provider's terms
and privacy practices apply. Downloads, updates, standard license services,
and hosted providers still require an internet connection.

The Neovim plugin connects only to the local Refine app through a same-UID
Unix-domain socket using Refine's current per-launch token. This boundary
excludes network clients and other OS users, but it does not identify a
specific plugin or protect against another process already running as you. The
plugin makes no direct network, telemetry, analytics, or update-check requests.
Persistent diagnostics are off by default; when enabled for troubleshooting,
they retain only bounded, redacted metadata and never source, diffs,
explanations, launch tokens, or provider credentials.

`:RefineReport` is a separate, explicit feedback action. Only when you invoke
it, the Refine app may send original and revised excerpts plus suggestion,
model, language, custom-instruction, Refine-version, and macOS-version context
to Refine's feedback service.

Read [How Refine works](https://refine.sh/guides/how-refine-works?utm_source=refine.nvim&utm_medium=readme),
the [offline grammar checker guide](https://refine.sh/guides/offline-grammar-checker-mac?utm_source=refine.nvim&utm_medium=readme),
and the [privacy policy](https://refine.sh/privacy-policy?utm_source=refine.nvim&utm_medium=readme)
for full details.

## Protocol compatibility and support

Integration Protocol 1.0 is a supported public API that third-party
writing-host clients may implement. Refine for Neovim requires the exact 1.0
wire contract. Refine maintains exact Protocol 1.0 compatibility throughout
the Refine 1.x release line.

The supported production profile connects a conforming writing-host client to
the shipping Refine server on the same Mac and as the same OS user, with Refine
already running. Network transports, cross-user access, and third-party
production servers are outside that profile. Technical conformance is
self-assessed and does not imply certification or endorsement.

A protocol mismatch stops before source is sent and reports the exact local
and remote versions. Because version ordering does not identify which
component should change, the diagnostic asks for a compatible app-and-plugin
pair without inferring an update direction.

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
