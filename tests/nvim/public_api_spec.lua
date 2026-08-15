local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("works without setup in an eligible buffer", function()
  vim.cmd.enew({ bang = true })
  vim.bo.buftype = ""
  vim.bo.filetype = "markdown"
  vim.bo.modifiable = true
  vim.bo.readonly = false
  vim.bo.binary = false

  local refine = require("refine")

  harness.equal({
    state = "inactive",
    bufnr = vim.api.nvim_get_current_buf(),
    reason = "no_ui",
  }, refine.status())
  harness.equal("", refine.statusline())
end)

harness.test("setup replaces configuration atomically", function()
  vim.cmd.enew({ bang = true })
  vim.bo.buftype = ""
  vim.bo.filetype = "markdown"

  local refine = require("refine")
  refine.setup({ filetypes = { markdown = false } })
  harness.equal("unsupported_filetype", refine.status().reason)

  local ok, failure = pcall(refine.setup, { unknown = true })
  harness.equal(false, ok)
  harness.matches("unknown configuration key", failure)
  harness.equal("unsupported_filetype", refine.status().reason)

  refine.setup({})
  harness.equal("no_ui", refine.status().reason)
end)

harness.test("configure_buffer replaces a validated local override", function()
  vim.cmd.enew({ bang = true })
  vim.bo.buftype = ""
  vim.bo.filetype = "quarto"

  local refine = require("refine")
  refine.setup({})
  local bufnr = vim.api.nvim_get_current_buf()
  harness.equal("unsupported_filetype", refine.status(bufnr).reason)

  refine.configure_buffer(bufnr, { enabled = true, source_syntax = "mixed" })
  harness.equal("no_ui", refine.status(bufnr).reason)

  refine.configure_buffer(bufnr, { enabled = false })
  harness.equal("disabled", refine.status(bufnr).reason)

  local ok, failure = pcall(refine.configure_buffer, bufnr, { source_syntax = "html" })
  harness.equal(false, ok)
  harness.matches("unsupported source syntax", failure)
  harness.equal("disabled", refine.status(bufnr).reason)

  refine.configure_buffer(bufnr, {})
  harness.equal("unsupported_filetype", refine.status(bufnr).reason)
end)

harness.run()
