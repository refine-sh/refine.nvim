local root = vim.fn.getcwd()
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local harness = require("support.harness")

harness.test("converts document UTF-16 at Unicode-scalar boundaries", function()
  local coordinates = require("refine.nvim.coordinates").new({
    "A😀é",
    "👩‍💻Z",
  })

  harness.equal({ row = 0, byte_col = 5 }, coordinates:position(3))
  harness.equal({ row = 0, byte_col = 6 }, coordinates:position(4))
  harness.equal({ row = 1, byte_col = 0 }, coordinates:position(6))
  harness.equal({ row = 1, byte_col = 4 }, coordinates:position(8))
  harness.equal({ row = 1, byte_col = 7 }, coordinates:position(9))
  harness.equal({ row = 1, byte_col = 11 }, coordinates:position(11))
  harness.equal(11, coordinates:utf16_offset(1, 11))
  harness.equal({
    start = { row = 0, byte_col = 5 },
    finish = { row = 1, byte_col = 0 },
  }, coordinates:range({ location = 3, length = 3 }))

  for _, invalid in ipairs({ 2, 7, 10 }) do
    local ok, failure = pcall(coordinates.position, coordinates, invalid)
    harness.equal(false, ok)
    harness.matches("Unicode%-scalar boundary", failure)
  end
end)

harness.run()
