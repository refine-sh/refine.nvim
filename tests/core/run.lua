local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = table.concat({
  root .. "/lua/?.lua",
  root .. "/lua/?/init.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local tests = {}

function _G.describe(_, body)
  body()
end

function _G.it(name, body)
  tests[#tests + 1] = { name = name, body = body }
end

local function inspect(value)
  return vim.inspect(value)
end

function _G.assert_equal(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(("expected %s\nactual   %s"):format(inspect(expected), inspect(actual)), 2)
  end
end

function _G.assert_truthy(value, message)
  if not value then
    error(message or ("expected truthy, got " .. inspect(value)), 2)
  end
end

function _G.assert_matches(pattern, value)
  if type(value) ~= "string" or not value:match(pattern) then
    error(("expected %s to match %s"):format(inspect(value), inspect(pattern)), 2)
  end
end

function _G.assert_raises(pattern, body)
  local ok, err = pcall(body)
  if ok then
    error("expected an error", 2)
  end
  if pattern and not tostring(err):match(pattern) then
    error(("expected error %s to match %s"):format(inspect(err), inspect(pattern)), 2)
  end
end

local specs = vim.fn.glob(root .. "/tests/core/*_spec.lua", false, true)
table.sort(specs)
for _, path in ipairs(specs) do
  dofile(path)
end

local failures = {}
for _, test in ipairs(tests) do
  local ok, err = xpcall(test.body, debug.traceback)
  if ok then
    io.stdout:write("ok - " .. test.name .. "\n")
  else
    failures[#failures + 1] = { name = test.name, error = err }
    io.stderr:write("not ok - " .. test.name .. "\n" .. err .. "\n")
  end
end

if #failures > 0 then
  io.stderr:write(("%d/%d tests failed\n"):format(#failures, #tests))
  os.exit(1)
end

io.stdout:write(("%d tests passed\n"):format(#tests))
