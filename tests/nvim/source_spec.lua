local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("snapshots canonical buffer text with incarnation revisions", function()
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Alpha", "😀" })
  vim.bo[bufnr].fileformat = "dos"
  vim.bo[bufnr].endofline = false

  local source = require("refine.nvim.source").new({
    bufnr = bufnr,
    source_syntax = "markdownDocument",
    run_id = "run",
  })

  local first = source:snapshot()
  harness.equal("run:1", first.revision)
  harness.equal({
    sourceId = "document",
    text = "Alpha\n😀",
    sourceSyntax = "markdownDocument",
  }, first.sources[1])
  harness.equal(first, source:snapshot())

  vim.api.nvim_buf_set_lines(bufnr, 0, 1, true, { "Beta" })
  harness.equal("run:2", source:snapshot().revision)
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, true, { "Alpha" })
  harness.equal("run:3", source:snapshot().revision)

  vim.bo[bufnr].fileformat = "unix"
  vim.bo[bufnr].endofline = true
  harness.equal("run:3", source:snapshot().revision)
end)

harness.run()
