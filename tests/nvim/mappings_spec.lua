local root = vim.fn.getcwd()
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")

local harness = require("support.harness")

harness.test("restores a saved buffer mapping even from another buffer", function()
  vim.cmd.enew({ bang = true })
  local owner = vim.api.nvim_get_current_buf()
  vim.keymap.set("n", "<Tab>", "owner", { buffer = owner })
  local mappings = require("refine.nvim.mappings").new(owner)
  mappings:set("n", "<Tab>", "temporary", { desc = "Temporary" })

  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  mappings:restore()
  harness.equal(
    "owner",
    vim.api.nvim_buf_call(owner, function()
      return vim.fn.maparg("<Tab>", "n", false, true).rhs
    end)
  )
  harness.equal(
    {},
    vim.api.nvim_buf_call(other, function()
      return vim.fn.maparg("<Tab>", "n", false, true)
    end)
  )
end)

harness.run()
