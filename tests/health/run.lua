local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local specs = vim.fn.glob(root .. "/tests/health/*_spec.lua", false, true)
table.sort(specs)
for _, path in ipairs(specs) do
  dofile(path)
end

require("support.harness").run()
