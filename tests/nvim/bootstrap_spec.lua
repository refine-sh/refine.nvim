local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")

local harness = require("support.harness")

harness.test("loads as a standard runtime plugin without setup", function()
  vim.cmd("runtime plugin/refine.lua")
  harness.equal(2, vim.fn.exists(":RefineCheck"))
  harness.equal(2, vim.fn.exists(":RefineStatus"))
  harness.equal(true, vim.fn.maparg("<Plug>(RefineShow)", "n") ~= "")

  vim.cmd.enew({ bang = true })
  vim.bo.filetype = "markdown"
  harness.equal("no_ui", require("refine").status().reason)
end)

harness.run()
