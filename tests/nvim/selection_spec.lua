local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")
local selection = require("refine.nvim.selection")

local function buffer(lines)
  vim.cmd.enew({ bang = true })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  return bufnr
end

harness.test("converts Ex line ranges to canonical UTF-16 selections", function()
  local bufnr = buffer({ "one", "two 😀", "three" })
  harness.equal({
    selection = {
      sourceId = "document",
      range = { location = 4, length = 7 },
    },
  }, selection.linewise(bufnr, 2, 2))

  harness.equal({
    selection = {
      sourceId = "document",
      range = { location = 0, length = 11 },
    },
  }, selection.linewise(bufnr, 1, 2))

  harness.equal({
    selection = {
      sourceId = "document",
      range = { location = 4, length = 12 },
    },
  }, selection.linewise(bufnr, 2, 3))
end)

harness.test("preserves exact inclusive characterwise grapheme endpoints", function()
  local bufnr = buffer({ "a é 😀 z", "last" })
  harness.equal({
    selection = {
      sourceId = "document",
      range = { location = 2, length = 5 },
    },
  }, selection.characterwise(bufnr, { 1, 2 }, { 1, 6 }, false))

  harness.equal({
    selection = {
      sourceId = "document",
      range = { location = 2, length = 3 },
    },
  }, selection.characterwise(bufnr, { 1, 2 }, { 1, 6 }, true))
end)

harness.test("rejects blockwise selections actionably", function()
  local ok, err = pcall(selection.visual_kind, "\22")
  harness.equal(false, ok)
  harness.matches("blockwise selections are not supported", err)
end)

harness.run()
