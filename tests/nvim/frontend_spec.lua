local root = vim.fn.getcwd()
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")

local harness = require("support.harness")
local frontend = require("refine.frontend")

harness.test("uses explicit recognized frontend identity", function()
  harness.equal({ id = "kitty" }, frontend.detect("kitty"))
end)

harness.test("omits automatic identity without exactly one UI", function()
  harness.equal(nil, frontend.detect("auto"))
end)

harness.run()
